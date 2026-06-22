```elixir
defmodule Compliance.AuditLog do
  @moduledoc """
  Records immutable audit entries for security-relevant system actions.

  Each entry captures who performed an action, on which resource, when,
  and from which IP address. Entries are append-only: no updates or deletes
  are permitted through this context.
  """

  import Ecto.Query

  alias Compliance.Repo
  alias Compliance.AuditLog.{Entry, Query}

  @type actor :: %{id: String.t(), type: :user | :service}
  @type resource :: %{id: String.t(), type: String.t()}

  @type record_opts :: [
          ip_address: String.t(),
          metadata: map()
        ]

  @doc """
  Records a new audit entry for the given actor, action, and resource.
  """
  @spec record(actor(), String.t(), resource(), record_opts()) ::
          {:ok, Entry.t()} | {:error, Ecto.Changeset.t()}
  def record(%{id: actor_id, type: actor_type}, action, %{id: res_id, type: res_type}, opts \\ [])
      when is_binary(actor_id) and is_atom(actor_type) and is_binary(action) and
             is_binary(res_id) and is_binary(res_type) do
    attrs = %{
      actor_id: actor_id,
      actor_type: actor_type,
      action: action,
      resource_id: res_id,
      resource_type: res_type,
      ip_address: Keyword.get(opts, :ip_address),
      metadata: Keyword.get(opts, :metadata, %{}),
      occurred_at: DateTime.utc_now()
    }

    %Entry{}
    |> Entry.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Returns a paginated list of audit entries filtered by the given query parameters.
  """
  @spec list(Query.t(), keyword()) :: %{entries: [Entry.t()], total: non_neg_integer()}
  def list(%Query{} = query, opts \\ []) do
    page = Keyword.get(opts, :page, 1)
    per_page = Keyword.get(opts, :per_page, 50)

    base = build_base_query(query)

    total = Repo.aggregate(base, :count, :id)

    entries =
      base
      |> order_by([e], desc: e.occurred_at)
      |> limit(^per_page)
      |> offset(^((page - 1) * per_page))
      |> Repo.all()

    %{entries: entries, total: total}
  end

  @doc """
  Returns the most recent audit entry for a specific resource.
  """
  @spec latest_for_resource(String.t(), String.t()) :: Entry.t() | nil
  def latest_for_resource(resource_id, resource_type)
      when is_binary(resource_id) and is_binary(resource_type) do
    Entry
    |> where([e], e.resource_id == ^resource_id and e.resource_type == ^resource_type)
    |> order_by([e], desc: e.occurred_at)
    |> limit(1)
    |> Repo.one()
  end

  defp build_base_query(%Query{actor_id: aid, action: action, resource_type: rt, since: since}) do
    Entry
    |> filter_by_actor(aid)
    |> filter_by_action(action)
    |> filter_by_resource_type(rt)
    |> filter_since(since)
  end

  defp filter_by_actor(q, nil), do: q
  defp filter_by_actor(q, id), do: where(q, [e], e.actor_id == ^id)

  defp filter_by_action(q, nil), do: q
  defp filter_by_action(q, action), do: where(q, [e], e.action == ^action)

  defp filter_by_resource_type(q, nil), do: q
  defp filter_by_resource_type(q, rt), do: where(q, [e], e.resource_type == ^rt)

  defp filter_since(q, nil), do: q
  defp filter_since(q, dt), do: where(q, [e], e.occurred_at >= ^dt)
end

defmodule Compliance.AuditLog.Query do
  @moduledoc "Filter parameters for audit log queries."

  defstruct actor_id: nil, action: nil, resource_type: nil, since: nil

  @type t :: %__MODULE__{
          actor_id: String.t() | nil,
          action: String.t() | nil,
          resource_type: String.t() | nil,
          since: DateTime.t() | nil
        }

  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    %__MODULE__{
      actor_id: Keyword.get(opts, :actor_id),
      action: Keyword.get(opts, :action),
      resource_type: Keyword.get(opts, :resource_type),
      since: Keyword.get(opts, :since)
    }
  end
end
```
