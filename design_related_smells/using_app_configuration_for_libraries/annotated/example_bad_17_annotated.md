# Annotated Example 17

## Metadata

- **Smell name:** Using App Configuration for libraries
- **Expected smell location:** `AuditLogger.purge_old_entries/0`
- **Affected function(s):** `purge_old_entries/0`
- **Short explanation:** `AuditLogger.purge_old_entries/0` reads `:retention_days` from the application environment instead of accepting it as a parameter. Because the retention window is global, calling code cannot selectively purge different categories of audit events with different retention periods (e.g., 30 days for access logs vs. 365 days for financial events) without altering global config.

## Code

```elixir
defmodule AuditLogger do
  @moduledoc """
  A library for recording and querying structured audit-log events in an Ecto
  repository. Supports categorized events, actor tracking, and time-based
  retention purging.

  Configuration in `config/config.exs`:

      config :audit_logger,
        repo: MyApp.Repo,
        retention_days: 90
  """

  alias AuditLogger.{Entry, Repo}

  @valid_levels [:info, :warning, :critical]

  @doc """
  Records an audit event for the given actor and action.

  `attrs` must include:
    - `:actor_id` – binary identifier of the user or service performing the action
    - `:action`   – atom describing the event (e.g., `:login`, `:invoice_created`)
    - `:resource` – map describing the affected resource (type + id)

  Optional:
    - `:level`    – one of `:info`, `:warning`, `:critical` (default `:info`)
    - `:metadata` – arbitrary map for additional context
  """
  def log(attrs) when is_map(attrs) do
    level = Map.get(attrs, :level, :info)

    unless level in @valid_levels do
      raise ArgumentError, "invalid audit level: #{inspect(level)}"
    end

    repo = Application.fetch_env!(:audit_logger, :repo)

    entry =
      Entry.changeset(%Entry{}, %{
        actor_id: Map.fetch!(attrs, :actor_id),
        action: Map.fetch!(attrs, :action) |> to_string(),
        resource_type: get_in(attrs, [:resource, :type]) |> to_string(),
        resource_id: get_in(attrs, [:resource, :id]) |> to_string(),
        level: to_string(level),
        metadata: Map.get(attrs, :metadata, %{}),
        occurred_at: DateTime.utc_now()
      })

    repo.insert(entry)
  end

  @doc """
  Returns the most recent audit events, ordered newest first.
  """
  def recent(limit \\ 50) when is_integer(limit) and limit > 0 do
    repo = Application.fetch_env!(:audit_logger, :repo)

    Entry
    |> Entry.order_by_recent()
    |> Entry.limit(limit)
    |> repo.all()
  end

  @doc """
  Returns all events for the given actor, newest first.
  """
  def for_actor(actor_id, limit \\ 100) when is_binary(actor_id) do
    repo = Application.fetch_env!(:audit_logger, :repo)

    Entry
    |> Entry.where_actor(actor_id)
    |> Entry.order_by_recent()
    |> Entry.limit(limit)
    |> repo.all()
  end

  @doc """
  Deletes audit entries older than the configured retention window.

  Returns `{:ok, count}` with the number of records deleted.

  The retention window is read from the application environment:

      config :audit_logger, retention_days: 90
  """
  # VALIDATION: SMELL START - Using App Configuration for libraries
  # VALIDATION: This is a smell because retention_days is fetched from the
  # Application Environment instead of being accepted as a parameter.
  # A caller managing different event categories with different regulatory
  # retention requirements cannot call this function with distinct cutoffs
  # for each category without modifying global application config.
  def purge_old_entries do
    retention_days = Application.fetch_env!(:audit_logger, :retention_days)
    repo = Application.fetch_env!(:audit_logger, :repo)

    cutoff = DateTime.add(DateTime.utc_now(), -retention_days * 86_400, :second)

    {count, _} =
      Entry
      |> Entry.before(cutoff)
      |> repo.delete_all()

    {:ok, count}
  end
  # VALIDATION: SMELL END

  @doc """
  Returns event counts grouped by action for a given time range.
  """
  def summary(from, to) when is_struct(from, DateTime) and is_struct(to, DateTime) do
    repo = Application.fetch_env!(:audit_logger, :repo)

    Entry
    |> Entry.between(from, to)
    |> Entry.group_by_action()
    |> repo.all()
  end
end
```
