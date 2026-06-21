```elixir
defmodule Audit.Trail do
  @moduledoc """
  Writes structured audit log entries to a persistent store and provides
  querying capabilities. Each entry captures who performed an action, on
  what resource, from what IP, and when. Queries support cursor-based
  pagination to avoid loading unbounded result sets.
  """

  import Ecto.Query, warn: false

  alias MyApp.Repo
  alias Audit.Entry

  @type actor_id :: String.t()
  @type resource_type :: String.t()
  @type resource_id :: String.t()
  @type action :: String.t()

  @type log_params :: %{
          actor_id: actor_id(),
          action: action(),
          resource_type: resource_type(),
          resource_id: resource_id(),
          metadata: map(),
          ip_address: String.t() | nil
        }

  @type query_opts :: [
          actor_id: actor_id(),
          resource_type: resource_type(),
          resource_id: resource_id(),
          before: DateTime.t(),
          limit: pos_integer()
        ]

  @default_limit 50
  @max_limit 200

  @doc """
  Writes a single audit entry. Returns the persisted entry or a changeset
  error when required fields are missing or invalid.
  """
  @spec log(log_params()) :: {:ok, Entry.t()} | {:error, Ecto.Changeset.t()}
  def log(%{actor_id: _, action: _, resource_type: _, resource_id: _} = params) do
    %Entry{}
    |> Entry.changeset(params)
    |> Repo.insert()
  end

  @doc """
  Queries audit entries with optional filters. Results are returned in
  reverse-chronological order. Limits are capped at #{@max_limit}.
  """
  @spec query(query_opts()) :: [Entry.t()]
  def query(opts \\ []) do
    limit = opts |> Keyword.get(:limit, @default_limit) |> min(@max_limit)

    Entry
    |> maybe_filter_actor(Keyword.get(opts, :actor_id))
    |> maybe_filter_resource_type(Keyword.get(opts, :resource_type))
    |> maybe_filter_resource_id(Keyword.get(opts, :resource_id))
    |> maybe_filter_before(Keyword.get(opts, :before))
    |> order_by([e], desc: e.inserted_at, desc: e.id)
    |> limit(^limit)
    |> Repo.all()
  end

  @doc "Returns the count of entries matching the given filters."
  @spec count(query_opts()) :: non_neg_integer()
  def count(opts \\ []) do
    Entry
    |> maybe_filter_actor(Keyword.get(opts, :actor_id))
    |> maybe_filter_resource_type(Keyword.get(opts, :resource_type))
    |> maybe_filter_resource_id(Keyword.get(opts, :resource_id))
    |> select([e], count(e.id))
    |> Repo.one()
  end

  defp maybe_filter_actor(q, nil), do: q
  defp maybe_filter_actor(q, actor_id), do: where(q, [e], e.actor_id == ^actor_id)

  defp maybe_filter_resource_type(q, nil), do: q
  defp maybe_filter_resource_type(q, rt), do: where(q, [e], e.resource_type == ^rt)

  defp maybe_filter_resource_id(q, nil), do: q
  defp maybe_filter_resource_id(q, rid), do: where(q, [e], e.resource_id == ^rid)

  defp maybe_filter_before(q, nil), do: q
  defp maybe_filter_before(q, dt), do: where(q, [e], e.inserted_at < ^dt)
end
```
