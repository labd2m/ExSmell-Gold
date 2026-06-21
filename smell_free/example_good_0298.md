```elixir
defmodule Compliance.DataRetentionPolicy do
  @moduledoc """
  Evaluates and enforces data retention rules across domain record types.
  Each record type declares a maximum retention duration. The policy module
  computes expiry dates, identifies records due for deletion, and delegates
  purging to the relevant context modules. Runs are idempotent so the same
  window can be evaluated multiple times without double-deletion.
  """

  require Logger

  alias MyApp.Repo
  import Ecto.Query, warn: false

  @type record_class :: :audit_entries | :session_tokens | :analytics_events | :temp_uploads
  @type run_summary :: %{record_class() => %{evaluated: non_neg_integer(), purged: non_neg_integer()}}

  @retention_days %{
    audit_entries: 365,
    session_tokens: 30,
    analytics_events: 90,
    temp_uploads: 7
  }

  @doc """
  Evaluates all registered record classes and purges records older than
  their configured retention period. Returns a per-class summary.
  """
  @spec run() :: {:ok, run_summary()}
  def run do
    summary =
      Map.new(@retention_days, fn {class, days} ->
        cutoff = cutoff_date(days)
        result = purge_class(class, cutoff)
        {class, result}
      end)

    {:ok, summary}
  end

  @doc "Returns the retention cutoff date for the given record class."
  @spec cutoff_for(record_class()) :: {:ok, Date.t()} | {:error, :unknown_class}
  def cutoff_for(class) when is_atom(class) do
    case Map.get(@retention_days, class) do
      nil -> {:error, :unknown_class}
      days -> {:ok, cutoff_date(days)}
    end
  end

  @doc "Returns the configured retention period in days for a record class."
  @spec retention_days(record_class()) :: {:ok, pos_integer()} | {:error, :unknown_class}
  def retention_days(class) when is_atom(class) do
    case Map.get(@retention_days, class) do
      nil -> {:error, :unknown_class}
      days -> {:ok, days}
    end
  end

  defp purge_class(:audit_entries, cutoff) do
    {count, _} = Repo.delete_all(from(e in "audit_entries", where: e.inserted_at < ^cutoff))
    Logger.info("[DataRetention] audit_entries: purged #{count} record(s) older than #{cutoff}")
    %{evaluated: count, purged: count}
  end

  defp purge_class(:session_tokens, cutoff) do
    {count, _} = Repo.delete_all(from(t in "session_tokens", where: t.expires_at < ^cutoff))
    Logger.info("[DataRetention] session_tokens: purged #{count} record(s)")
    %{evaluated: count, purged: count}
  end

  defp purge_class(:analytics_events, cutoff) do
    {count, _} = Repo.delete_all(from(e in "analytics_events", where: e.occurred_at < ^cutoff))
    Logger.info("[DataRetention] analytics_events: purged #{count} record(s)")
    %{evaluated: count, purged: count}
  end

  defp purge_class(:temp_uploads, cutoff) do
    {count, _} = Repo.delete_all(from(u in "temp_uploads", where: u.created_at < ^cutoff and u.claimed == false))
    Logger.info("[DataRetention] temp_uploads: purged #{count} record(s)")
    %{evaluated: count, purged: count}
  end

  defp cutoff_date(days) do
    Date.utc_today() |> Date.add(-days)
  end
end
```
