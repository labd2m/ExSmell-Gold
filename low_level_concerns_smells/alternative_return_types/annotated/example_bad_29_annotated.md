# Code Smell: Alternative Return Types

## Metadata

- **Smell name:** Alternative Return Types
- **Expected smell location:** `Compliance.DataRetention.purge/2`
- **Affected function(s):** `purge/2`
- **Short explanation:** The `:report` option changes the return from a plain integer (records deleted), to a `{:ok, %PurgeReport{}}` struct, to a dry-run list of record IDs that would have been deleted. All three correspond to different modes of the same operation, but returning different types makes it impossible to write a generic caller.

---

```elixir
defmodule MyApp.Compliance.DataRetention do
  @moduledoc """
  Enforces data retention policies by purging or anonymising records that
  have exceeded their retention period. Complies with LGPD and GDPR
  deletion requirements. Supports dry-run mode for pre-purge auditing.
  """

  alias MyApp.Compliance.RetentionPolicy
  alias MyApp.Compliance.PurgeReport
  alias MyApp.Compliance.AnonymisationWorker
  alias MyApp.Repo

  @supported_entities [:users, :orders, :audit_logs, :session_tokens, :messages]
  @default_batch_size 500

  def policy_for(entity) do
    RetentionPolicy.fetch(entity)
  end

  def overdue_records(entity, cutoff_date) do
    RetentionPolicy.query_overdue(entity, cutoff_date)
    |> Repo.all()
  end

  # VALIDATION: SMELL START - Alternative Return Types
  # VALIDATION: This is a smell because opts[:report] changes the return type:
  # :count returns a plain non-negative integer (number of records purged/would
  # be purged), :full returns {:ok, %PurgeReport{}} with timestamps, entity
  # breakdown, and errors, and :dry_run returns a list of record ID binaries
  # that would be affected without actually deleting anything.
  # :count and :dry_run both avoid side-effects in some modes, but return
  # completely different types, making the contract of the function ambiguous.
  def purge(entity, opts \\ []) when is_list(opts) do
    report = Keyword.get(opts, :report, :count)
    batch_size = Keyword.get(opts, :batch_size, @default_batch_size)
    anonymise_instead = Keyword.get(opts, :anonymise, false)
    cutoff = Keyword.get(opts, :cutoff, cutoff_for(entity))

    unless entity in @supported_entities do
      raise ArgumentError, "unsupported entity: #{inspect(entity)}"
    end

    overdue =
      RetentionPolicy.query_overdue(entity, cutoff)
      |> Repo.all()

    case report do
      :dry_run ->
        Enum.map(overdue, & &1.id)

      :count ->
        overdue
        |> Enum.chunk_every(batch_size)
        |> Enum.reduce(0, fn batch, acc ->
          deleted = execute_purge(batch, entity, anonymise_instead)
          acc + deleted
        end)

      :full ->
        started_at = DateTime.utc_now()
        errors = []
        total_deleted = 0

        {total_deleted, errors} =
          overdue
          |> Enum.chunk_every(batch_size)
          |> Enum.reduce({0, []}, fn batch, {count, errs} ->
            try do
              n = execute_purge(batch, entity, anonymise_instead)
              {count + n, errs}
            rescue
              e -> {count, [Exception.message(e) | errs]}
            end
          end)

        {:ok,
         %PurgeReport{
           entity: entity,
           cutoff_date: cutoff,
           records_affected: total_deleted,
           errors: Enum.reverse(errors),
           anonymised: anonymise_instead,
           started_at: started_at,
           finished_at: DateTime.utc_now()
         }}
    end
  end
  # VALIDATION: SMELL END

  def schedule_purge(entity, opts \\ []) do
    cron_expr = RetentionPolicy.cron_schedule(entity)
    %{entity: entity, cron: cron_expr, opts: opts}
  end

  defp execute_purge(batch, _entity, false) do
    ids = Enum.map(batch, & &1.id)
    {count, _} = Repo.delete_all_by_ids(batch |> hd() |> Map.fetch!(:__struct__), ids)
    count
  end

  defp execute_purge(batch, entity, true) do
    AnonymisationWorker.anonymise_batch(entity, Enum.map(batch, & &1.id))
    length(batch)
  end

  defp cutoff_for(entity) do
    days = RetentionPolicy.retention_days(entity)
    Date.add(Date.utc_today(), -days)
  end
end
```
