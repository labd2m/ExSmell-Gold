```elixir
defmodule Compliance.AuditLog do
  @moduledoc """
  Records structured audit log entries for security-sensitive operations
  across the platform. Each entry captures the actor, the target resource,
  the action performed, a diff of changed fields, and full request metadata.
  Writes are async-by-default to avoid adding latency to the critical path,
  with a synchronous fallback available for compliance-critical operations.
  """

  alias Compliance.{AuditEntry, Repo}
  import Ecto.Query

  require Logger

  @type actor :: %{id: binary(), type: :user | :system | :api_key}
  @type resource :: %{id: binary(), type: binary()}
  @type action :: binary()
  @type diff :: %{before: map(), after: map()}

  @type log_opts :: [
          diff: diff() | nil,
          metadata: map(),
          sync: boolean()
        ]

  @type filter_opts :: [
          actor_id: binary() | nil,
          resource_type: binary() | nil,
          resource_id: binary() | nil,
          action: binary() | nil,
          from: DateTime.t() | nil,
          until: DateTime.t() | nil,
          page: pos_integer(),
          per_page: pos_integer()
        ]

  # ---------------------------------------------------------------------------
  # Writing
  # ---------------------------------------------------------------------------

  @doc """
  Records an audit entry for the given actor, resource, and action.
  By default the write is asynchronous (fire-and-forget via `Task.Supervisor`).
  Pass `sync: true` to block until the entry is persisted, which is recommended
  for operations where auditability is a regulatory requirement.
  """
  @spec record(actor(), resource(), action(), log_opts()) :: :ok | {:ok, AuditEntry.t()} | {:error, term()}
  def record(actor, resource, action, opts \\ [])
      when is_map(actor) and is_map(resource) and is_binary(action) do
    attrs = build_attrs(actor, resource, action, opts)

    if Keyword.get(opts, :sync, false) do
      persist(attrs)
    else
      Task.Supervisor.start_child(Compliance.TaskSupervisor, fn ->
        case persist(attrs) do
          {:ok, _entry} -> :ok
          {:error, reason} -> Logger.error("Audit write failed", reason: inspect(reason), attrs: attrs)
        end
      end)

      :ok
    end
  end

  # ---------------------------------------------------------------------------
  # Querying
  # ---------------------------------------------------------------------------

  @doc """
  Returns a paginated list of audit log entries matching the given filters.
  """
  @spec list(filter_opts()) :: %{entries: [AuditEntry.t()], total: non_neg_integer()}
  def list(opts \\ []) do
    page = Keyword.get(opts, :page, 1)
    per_page = Keyword.get(opts, :per_page, 50)

    base =
      AuditEntry
      |> filter_by_actor(Keyword.get(opts, :actor_id))
      |> filter_by_resource_type(Keyword.get(opts, :resource_type))
      |> filter_by_resource_id(Keyword.get(opts, :resource_id))
      |> filter_by_action(Keyword.get(opts, :action))
      |> filter_by_time_range(Keyword.get(opts, :from), Keyword.get(opts, :until))

    total = Repo.aggregate(base, :count, :id)

    entries =
      base
      |> order_by([e], desc: e.inserted_at)
      |> limit(^per_page)
      |> offset(^((page - 1) * per_page))
      |> Repo.all()

    %{entries: entries, total: total}
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp build_attrs(actor, resource, action, opts) do
    %{
      actor_id: actor.id,
      actor_type: actor.type,
      resource_id: resource.id,
      resource_type: resource.type,
      action: action,
      diff_before: get_in(opts, [:diff, :before]),
      diff_after: get_in(opts, [:diff, :after]),
      metadata: Keyword.get(opts, :metadata, %{})
    }
  end

  defp persist(attrs) do
    %AuditEntry{}
    |> AuditEntry.changeset(attrs)
    |> Repo.insert()
  end

  defp filter_by_actor(query, nil), do: query
  defp filter_by_actor(query, actor_id), do: where(query, [e], e.actor_id == ^actor_id)

  defp filter_by_resource_type(query, nil), do: query
  defp filter_by_resource_type(query, type), do: where(query, [e], e.resource_type == ^type)

  defp filter_by_resource_id(query, nil), do: query
  defp filter_by_resource_id(query, id), do: where(query, [e], e.resource_id == ^id)

  defp filter_by_action(query, nil), do: query
  defp filter_by_action(query, action), do: where(query, [e], e.action == ^action)

  defp filter_by_time_range(query, nil, nil), do: query
  defp filter_by_time_range(query, from, nil) when not is_nil(from), do: where(query, [e], e.inserted_at >= ^from)
  defp filter_by_time_range(query, nil, until) when not is_nil(until), do: where(query, [e], e.inserted_at <= ^until)
  defp filter_by_time_range(query, from, until), do: where(query, [e], e.inserted_at >= ^from and e.inserted_at <= ^until)
end
```
