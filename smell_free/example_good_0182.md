```elixir
defmodule Platform.AuditLog do
  @moduledoc """
  Context for recording and querying tamper-evident audit log entries.

  Every write operation in the application that affects sensitive resources
  records an audit entry. Entries are append-only; no update or delete
  operations are exposed by this context.
  """

  import Ecto.Query, only: [from: 2]
  alias Platform.{Repo, AuditLog.Entry}

  @type actor :: %{id: pos_integer(), type: :user | :api_key | :system}
  @type resource :: %{id: pos_integer(), type: String.t()}
  @type action :: :created | :updated | :deleted | :viewed | :exported
  @type log_opts :: [changes: map(), metadata: map()]

  @doc """
  Records an audit event. Inserts synchronously to guarantee persistence
  before the calling operation returns.
  """
  @spec record(actor(), action(), resource(), log_opts()) ::
          {:ok, Entry.t()} | {:error, Ecto.Changeset.t()}
  def record(%{id: actor_id, type: actor_type}, action, %{id: resource_id, type: resource_type}, opts \\ []) do
    attrs = %{
      actor_id: actor_id,
      actor_type: actor_type,
      action: action,
      resource_id: resource_id,
      resource_type: resource_type,
      changes: Keyword.get(opts, :changes, %{}),
      metadata: Keyword.get(opts, :metadata, %{}),
      occurred_at: DateTime.utc_now()
    }

    %Entry{}
    |> Entry.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Returns a paginated, chronological audit trail for a specific resource.
  """
  @spec for_resource(String.t(), pos_integer(), keyword()) :: [Entry.t()]
  def for_resource(resource_type, resource_id, opts \\ [])
      when is_binary(resource_type) and is_integer(resource_id) do
    limit = Keyword.get(opts, :limit, 50)
    before_id = Keyword.get(opts, :before_id)

    from(e in Entry,
      where: e.resource_type == ^resource_type and e.resource_id == ^resource_id,
      order_by: [desc: e.occurred_at],
      limit: ^limit
    )
    |> apply_cursor(before_id)
    |> Repo.all()
  end

  @doc """
  Returns a paginated audit trail for all actions performed by a specific actor.
  """
  @spec for_actor(pos_integer(), atom(), keyword()) :: [Entry.t()]
  def for_actor(actor_id, actor_type, opts \\ [])
      when is_integer(actor_id) and is_atom(actor_type) do
    limit = Keyword.get(opts, :limit, 50)

    from(e in Entry,
      where: e.actor_id == ^actor_id and e.actor_type == ^actor_type,
      order_by: [desc: e.occurred_at],
      limit: ^limit
    )
    |> Repo.all()
  end

  @doc """
  Returns the count of audit entries for the given resource in a time range.
  """
  @spec count_in_range(String.t(), pos_integer(), DateTime.t(), DateTime.t()) :: non_neg_integer()
  def count_in_range(resource_type, resource_id, from_dt, to_dt) do
    from(e in Entry,
      where:
        e.resource_type == ^resource_type and
          e.resource_id == ^resource_id and
          e.occurred_at >= ^from_dt and
          e.occurred_at <= ^to_dt,
      select: count(e.id)
    )
    |> Repo.one()
  end

  defp apply_cursor(query, nil), do: query

  defp apply_cursor(query, before_id) when is_integer(before_id) do
    from(e in query, where: e.id < ^before_id)
  end
end
```
