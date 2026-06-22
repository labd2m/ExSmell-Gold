```elixir
defmodule Mix.Tasks.Data.Retention.Enforce do
  @moduledoc """
  Enforces data retention policies by purging records that have exceeded
  their configured retention window. Policies are declared per-schema
  with a field to check and a retention period in days.

  Runs in dry-run mode by default. Pass `--commit` to execute deletions.

  ## Usage

      mix data.retention.enforce
      mix data.retention.enforce --commit
      mix data.retention.enforce --commit --policy audit_logs

  """

  use Mix.Task

  import Ecto.Query, only: [from: 2]
  alias Platform.Repo

  @shortdoc "Purges records exceeding their data retention window"

  @policies [
    %{
      name: :audit_logs,
      schema: Platform.AuditLog.Entry,
      date_field: :occurred_at,
      retention_days: 365,
      description: "Audit log entries older than 1 year"
    },
    %{
      name: :session_tokens,
      schema: Platform.Auth.SessionToken,
      date_field: :expires_at,
      retention_days: 30,
      description: "Expired session tokens older than 30 days"
    },
    %{
      name: :webhook_delivery_logs,
      schema: Webhooks.DeliveryLog,
      date_field: :logged_at,
      retention_days: 90,
      description: "Webhook delivery logs older than 90 days"
    },
    %{
      name: :password_reset_tokens,
      schema: Accounts.PasswordResetToken,
      date_field: :expires_at,
      retention_days: 7,
      description: "Expired password reset tokens older than 7 days"
    }
  ]

  @impl Mix.Task
  def run(args) do
    {opts, _, _} =
      OptionParser.parse(args,
        strict: [commit: :boolean, policy: :string],
        aliases: [c: :commit]
      )

    commit? = Keyword.get(opts, :commit, false)
    policy_filter = Keyword.get(opts, :policy)

    Mix.Task.run("app.start")

    mode = if commit?, do: "COMMIT", else: "DRY RUN"
    Mix.shell().info("\n=== Data Retention Enforcement [#{mode}] ===\n")

    policies = filter_policies(@policies, policy_filter)
    results = Enum.map(policies, &enforce_policy(&1, commit?))
    print_summary(results, commit?)
  end

  defp filter_policies(policies, nil), do: policies

  defp filter_policies(policies, name_str) do
    name = String.to_existing_atom(name_str)
    Enum.filter(policies, &(&1.name == name))
  rescue
    ArgumentError ->
      Mix.shell().error("Unknown policy: #{name_str}")
      []
  end

  defp enforce_policy(%{schema: schema, date_field: field, retention_days: days, description: desc, name: name}, commit?) do
    cutoff = DateTime.add(DateTime.utc_now(), -days, :day)

    count_query = from(r in schema, where: field(r, ^field) < ^cutoff, select: count(r.id))
    count = Repo.one(count_query)

    Mix.shell().info("Policy: #{name}")
    Mix.shell().info("  #{desc}")
    Mix.shell().info("  Cutoff: #{DateTime.to_date(cutoff)}")
    Mix.shell().info("  Records eligible: #{count}")

    deleted =
      if commit? && count > 0 do
        {n, _} = from(r in schema, where: field(r, ^field) < ^cutoff) |> Repo.delete_all()
        Mix.shell().info("  Deleted: #{n}")
        n
      else
        if count > 0, do: Mix.shell().info("  Would delete: #{count} records")
        0
      end

    Mix.shell().info("")
    %{name: name, eligible: count, deleted: deleted}
  end

  defp print_summary(results, commit?) do
    total_eligible = Enum.sum(Enum.map(results, & &1.eligible))
    total_deleted = Enum.sum(Enum.map(results, & &1.deleted))

    Mix.shell().info("=== Summary ===")
    Mix.shell().info("  Policies checked : #{length(results)}")
    Mix.shell().info("  Records eligible : #{total_eligible}")

    if commit? do
      Mix.shell().info("  Records deleted  : #{total_deleted}")
    else
      Mix.shell().info("  Would delete     : #{total_eligible}")
      Mix.shell().info("\nRun with --commit to execute deletions.")
    end
  end
end
```
