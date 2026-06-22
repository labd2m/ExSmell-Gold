```elixir
defmodule Audit.EventLogger do
  @moduledoc """
  Records structured audit events for security-relevant user and system
  actions. Writes are batched through an Oban worker to avoid blocking
  the calling process during high-throughput request handling.
  """

  alias Audit.{Repo, AuditEvent}
  import Ecto.Query

  @type actor :: %{id: String.t(), type: :user | :service}

  @type event_params :: %{
          actor: actor(),
          action: atom(),
          resource_type: String.t(),
          resource_id: String.t(),
          outcome: :success | :failure,
          metadata: map()
        }

  @spec log(event_params()) :: {:ok, AuditEvent.t()} | {:error, Ecto.Changeset.t()}
  def log(params) when is_map(params) do
    %AuditEvent{}
    |> AuditEvent.creation_changeset(enrich(params))
    |> Repo.insert()
  end

  @spec log_async(event_params()) :: :ok
  def log_async(params) when is_map(params) do
    Oban.insert!(Audit.EventWriter.new(%{params: stringify_keys(params)}))
    :ok
  end

  @spec list_for_resource(String.t(), String.t(), keyword()) :: [AuditEvent.t()]
  def list_for_resource(resource_type, resource_id, opts \\ [])
      when is_binary(resource_type) and is_binary(resource_id) do
    limit = Keyword.get(opts, :limit, 50)
    since = Keyword.get(opts, :since)

    from(e in AuditEvent,
      where: e.resource_type == ^resource_type and e.resource_id == ^resource_id,
      order_by: [desc: e.inserted_at],
      limit: ^limit
    )
    |> apply_since_filter(since)
    |> Repo.all()
  end

  @spec list_for_actor(String.t(), keyword()) :: [AuditEvent.t()]
  def list_for_actor(actor_id, opts \\ []) when is_binary(actor_id) do
    limit = Keyword.get(opts, :limit, 50)

    from(e in AuditEvent,
      where: e.actor_id == ^actor_id,
      order_by: [desc: e.inserted_at],
      limit: ^limit
    )
    |> Repo.all()
  end

  @spec count_failures(String.t(), DateTime.t()) :: non_neg_integer()
  def count_failures(actor_id, since) when is_binary(actor_id) do
    from(e in AuditEvent,
      where:
        e.actor_id == ^actor_id and
          e.outcome == :failure and
          e.inserted_at >= ^since,
      select: count(e.id)
    )
    |> Repo.one()
  end

  @spec enrich(event_params()) :: map()
  defp enrich(params) do
    Map.merge(params, %{
      actor_id: params.actor.id,
      actor_type: params.actor.type,
      occurred_at: DateTime.utc_now(),
      node: to_string(node())
    })
  end

  @spec apply_since_filter(Ecto.Query.t(), DateTime.t() | nil) :: Ecto.Query.t()
  defp apply_since_filter(query, nil), do: query

  defp apply_since_filter(query, since) do
    from(e in query, where: e.inserted_at >= ^since)
  end

  @spec stringify_keys(map()) :: map()
  defp stringify_keys(map) do
    Map.new(map, fn {k, v} -> {to_string(k), v} end)
  end
end
```
