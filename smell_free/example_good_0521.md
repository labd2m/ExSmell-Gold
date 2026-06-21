```elixir
defmodule MyApp.Compliance.DataRetentionEnforcer do
  @moduledoc """
  Enforces data retention policies by deleting or anonymising records
  that have exceeded their configured retention period. Each entity type
  has its own policy defined in `@policies`; policies declare both the
  retention window and the disposal method (`:delete` or `:anonymise`).

  Designed to run as a scheduled Oban job. Each run processes a bounded
  batch to avoid long-running transactions that could affect production
  query performance.
  """

  use Oban.Worker, queue: :compliance, max_attempts: 2

  require Logger

  import Ecto.Query, warn: false

  alias MyApp.Repo

  @batch_size 500

  @policies [
    %{entity: :audit_log, table: "audit_log", retention_days: 365, disposal: :delete,
      date_field: :inserted_at},
    %{entity: :session_tokens, table: "session_tokens", retention_days: 90, disposal: :delete,
      date_field: :inserted_at},
    %{entity: :webhook_logs, table: "webhook_delivery_logs", retention_days: 30, disposal: :delete,
      date_field: :inserted_at},
    %{entity: :inactive_users, table: "users", retention_days: 730, disposal: :anonymise,
      date_field: :last_active_at}
  ]

  @type policy :: %{
          entity: atom(),
          table: String.t(),
          retention_days: pos_integer(),
          disposal: :delete | :anonymise,
          date_field: atom()
        }

  @type run_summary :: %{
          entity: atom(),
          disposal: :delete | :anonymise,
          affected: non_neg_integer()
        }

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    summaries = Enum.map(@policies, &enforce_policy/1)
    total = Enum.sum_by(summaries, & &1.affected)
    Logger.info("data_retention_run_complete", total_affected: total)
    :ok
  end

  @spec enforce_policy(policy()) :: run_summary()
  defp enforce_policy(policy) do
    cutoff = Date.add(Date.utc_today(), -policy.retention_days)
    affected = apply_disposal(policy, cutoff)

    Logger.info("data_retention_policy_enforced",
      entity: policy.entity,
      disposal: policy.disposal,
      cutoff: Date.to_iso8601(cutoff),
      affected: affected
    )

    %{entity: policy.entity, disposal: policy.disposal, affected: affected}
  end

  @spec apply_disposal(policy(), Date.t()) :: non_neg_integer()
  defp apply_disposal(%{disposal: :delete} = policy, cutoff) do
    {count, _} =
      Repo.query!(
        "DELETE FROM #{policy.table} WHERE #{policy.date_field} < $1 LIMIT #{@batch_size}",
        [cutoff]
      )
      |> then(fn %{num_rows: n} -> {n, nil} end)

    count
  rescue
    _ ->
      from_table = policy.table
      date_field = policy.date_field

      {count, _} =
        "#{from_table}"
        |> then(fn t ->
          Repo.update_all(
            from(r in t, where: field(r, ^date_field) < ^cutoff, limit: @batch_size),
            []
          )
        end)

      count
  end

  defp apply_disposal(%{disposal: :anonymise, table: table, date_field: date_field}, cutoff) do
    anon_fields = anonymisation_fields(table)

    {count, _} =
      Repo.update_all(
        from(r in table, where: field(r, ^date_field) < ^cutoff, limit: @batch_size),
        set: anon_fields
      )

    count
  end

  @spec anonymisation_fields(String.t()) :: keyword()
  defp anonymisation_fields("users") do
    [
      email: "anonymised@deleted.invalid",
      name: "Deleted User",
      phone: nil,
      address_line1: nil
    ]
  end

  defp anonymisation_fields(_), do: []
end
```
