# File: `example_good_82.md`

```elixir
defmodule Audit.Trail do
  @moduledoc """
  Append-only audit trail for recording domain events with their actor,
  target resource, and structured metadata.

  All writes are fire-and-forget via an async Task under the application
  supervisor. Reads provide flexible filtering and pagination so consumers
  can query history without loading entire tables.
  """

  import Ecto.Query, warn: false

  alias Audit.{Entry, Repo}

  @type actor :: %{id: String.t(), type: :user | :system | :api_key}
  @type resource :: %{id: String.t(), type: String.t()}

  @type filter_opts :: [
          actor_id: String.t(),
          resource_type: String.t(),
          resource_id: String.t(),
          action: String.t(),
          from: DateTime.t(),
          until: DateTime.t()
        ]

  @doc """
  Records an audit event asynchronously.

  The write is dispatched to a supervised Task so it never blocks
  the calling process. Failures are logged but do not propagate
  to the caller.

  Returns `:ok` immediately.
  """
  @spec record(actor(), resource(), String.t(), map()) :: :ok
  def record(%{id: actor_id, type: actor_type}, %{id: res_id, type: res_type}, action, metadata)
      when is_binary(actor_id) and is_atom(actor_type) and
             is_binary(res_id) and is_binary(res_type) and
             is_binary(action) and is_map(metadata) do
    Task.Supervisor.start_child(Audit.TaskSupervisor, fn ->
      persist_entry(actor_id, actor_type, res_id, res_type, action, metadata)
    end)

    :ok
  end

  @doc """
  Returns a paginated list of audit entries matching the given filters.

  Returns `{:ok, %{entries: [Entry.t()], total: integer}}`.
  """
  @spec query(filter_opts(), pos_integer(), pos_integer()) ::
          {:ok, %{entries: [Entry.t()], total: non_neg_integer()}}
  def query(filters, page, per_page)
      when is_list(filters) and is_integer(page) and page > 0 and
             is_integer(per_page) and per_page > 0 do
    base = build_base_query(filters)
    total = Repo.aggregate(base, :count, :id)

    entries =
      base
      |> order_by([e], desc: e.inserted_at)
      |> limit(^per_page)
      |> offset(^((page - 1) * per_page))
      |> Repo.all()

    {:ok, %{entries: entries, total: total}}
  end

  @doc """
  Returns the most recent audit entry for a specific resource, if any.
  """
  @spec latest_for_resource(String.t(), String.t()) ::
          {:ok, Entry.t()} | {:error, :not_found}
  def latest_for_resource(resource_type, resource_id)
      when is_binary(resource_type) and is_binary(resource_id) do
    result =
      Entry
      |> where([e], e.resource_type == ^resource_type and e.resource_id == ^resource_id)
      |> order_by([e], desc: e.inserted_at)
      |> limit(1)
      |> Repo.one()

    case result do
      nil -> {:error, :not_found}
      entry -> {:ok, entry}
    end
  end

  defp build_base_query(filters) do
    Enum.reduce(filters, Entry, &apply_filter/2)
  end

  defp apply_filter({:actor_id, id}, query) do
    where(query, [e], e.actor_id == ^id)
  end

  defp apply_filter({:resource_type, type}, query) do
    where(query, [e], e.resource_type == ^type)
  end

  defp apply_filter({:resource_id, id}, query) do
    where(query, [e], e.resource_id == ^id)
  end

  defp apply_filter({:action, action}, query) do
    where(query, [e], e.action == ^action)
  end

  defp apply_filter({:from, dt}, query) do
    where(query, [e], e.inserted_at >= ^dt)
  end

  defp apply_filter({:until, dt}, query) do
    where(query, [e], e.inserted_at <= ^dt)
  end

  defp apply_filter(_unknown, query), do: query

  defp persist_entry(actor_id, actor_type, res_id, res_type, action, metadata) do
    %{
      actor_id: actor_id,
      actor_type: actor_type,
      resource_id: res_id,
      resource_type: res_type,
      action: action,
      metadata: metadata
    }
    |> Entry.changeset()
    |> Repo.insert()
  end
end
```
