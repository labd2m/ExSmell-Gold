```elixir
defmodule Compliance.AuditLog do
  @moduledoc """
  Query interface for the compliance audit log.
  Supports raw entry retrieval, statistical aggregates, and export.
  """

  alias Compliance.Repo
  alias Compliance.Schema.AuditEntry

  import Ecto.Query

  @max_export_rows 50_000

  @doc """
  Queries the audit log with optional filters.

  ## Options

    * `:actor_id` — Filter by the user who performed the action.
    * `:resource_type` — Filter by resource type (e.g., `"Invoice"`).
    * `:action` — Filter by action atom (e.g., `:update`, `:delete`).
    * `:from` — `DateTime.t()` lower bound (inclusive).
    * `:to` — `DateTime.t()` upper bound (inclusive).
    * `:limit` — Max number of entries to return. Defaults to 100.
    * `:aggregate` — When `true`, returns a summary map instead of entries:
      `%{total: integer, by_actor: %{actor_id => count}, by_action: %{action => count}}`.
    * `:export` — When `true`, returns all matching entries serialized as
      Newline-Delimited JSON (NDJSON) binary. Overrides `:aggregate`.
      Capped at #{@max_export_rows} rows.

  ## Examples

      iex> query(actor_id: 7, action: :delete)
      [%AuditEntry{...}, ...]

      iex> query([from: ~U[2024-01-01 00:00:00Z]], aggregate: true)
      %{total: 832, by_actor: %{7 => 312, 14 => 520}, by_action: %{delete: 100, update: 732}}

      iex> query([resource_type: "Invoice"], export: true)
      "{\"id\":1,\"actor_id\":7,...}\n{\"id\":2,...}\n"

  """

  def query(filters \\ [], opts \\ []) when is_list(filters) and is_list(opts) do
    base = build_query(filters)

    cond do
      opts[:export] == true ->
        base
        |> limit(^@max_export_rows)
        |> order_by([e], asc: e.inserted_at)
        |> Repo.all()
        |> Enum.map_join("\n", &Jason.encode!(entry_to_map(&1)))

      opts[:aggregate] == true ->
        entries = Repo.all(base)
        by_actor = Enum.frequencies_by(entries, & &1.actor_id)
        by_action = Enum.frequencies_by(entries, & &1.action)
        %{total: length(entries), by_actor: by_actor, by_action: by_action}

      true ->
        limit = Keyword.get(opts, :limit, 100)

        base
        |> order_by([e], desc: e.inserted_at)
        |> limit(^limit)
        |> Repo.all()
    end
  end
  
  defp build_query(filters) do
    Enum.reduce(filters, from(e in AuditEntry), fn
      {:actor_id, id}, q ->
        where(q, [e], e.actor_id == ^id)

      {:resource_type, type}, q ->
        where(q, [e], e.resource_type == ^type)

      {:action, action}, q ->
        where(q, [e], e.action == ^action)

      {:from, dt}, q ->
        where(q, [e], e.inserted_at >= ^dt)

      {:to, dt}, q ->
        where(q, [e], e.inserted_at <= ^dt)

      _, q ->
        q
    end)
  end

  defp entry_to_map(%AuditEntry{} = e) do
    %{
      id: e.id,
      actor_id: e.actor_id,
      action: e.action,
      resource_type: e.resource_type,
      resource_id: e.resource_id,
      metadata: e.metadata,
      inserted_at: DateTime.to_iso8601(e.inserted_at)
    }
  end

  @doc """
  Inserts a new audit entry. Used by event handlers and middleware.
  """
  def record(actor_id, action, resource_type, resource_id, metadata \\ %{}) do
    %AuditEntry{}
    |> AuditEntry.changeset(%{
      actor_id: actor_id,
      action: action,
      resource_type: resource_type,
      resource_id: resource_id,
      metadata: metadata
    })
    |> Repo.insert()
  end

  @doc """
  Purges entries older than the given number of days.
  Returns the number of deleted rows.
  """
  def purge_older_than(days) when is_integer(days) and days > 0 do
    cutoff = DateTime.add(DateTime.utc_now(), -days * 86_400, :second)

    {count, _} =
      AuditEntry
      |> where([e], e.inserted_at < ^cutoff)
      |> Repo.delete_all()

    count
  end
end
```
