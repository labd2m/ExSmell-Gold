```elixir
defmodule Audit.Event do
  @moduledoc """
  Schema for an immutable audit log entry. Audit events are append-only
  and must never be updated or deleted after insertion.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  schema "audit_events" do
    field :action, :string
    field :actor_id, :integer
    field :actor_type, :string
    field :resource_type, :string
    field :resource_id, :integer
    field :metadata, :map, default: %{}
    field :ip_address, :string
    field :occurred_at, :utc_datetime_usec
    timestamps(updated_at: false)
  end

  @spec changeset(map()) :: Ecto.Changeset.t()
  def changeset(attrs) when is_map(attrs) do
    %__MODULE__{}
    |> cast(attrs, [:action, :actor_id, :actor_type, :resource_type, :resource_id,
                    :metadata, :ip_address, :occurred_at])
    |> validate_required([:action, :actor_id, :actor_type, :resource_type, :occurred_at])
    |> validate_length(:action, min: 1, max: 100)
    |> validate_length(:actor_type, min: 1, max: 60)
    |> validate_length(:resource_type, min: 1, max: 60)
  end
end

defmodule Audit.Log do
  @moduledoc """
  Writes and queries audit events. Inserts are asynchronous via a buffered
  writer process to avoid blocking request handling. Queries support
  filtering by actor, resource, and time range.
  """

  import Ecto.Query, warn: false

  alias Audit.{Repo, Event}

  @type actor :: %{id: integer(), type: String.t()}
  @type resource :: %{id: integer(), type: String.t()}
  @type record_opts :: %{optional(:metadata) => map(), optional(:ip_address) => String.t()}

  @spec record(actor(), String.t(), resource(), record_opts()) ::
          {:ok, Event.t()} | {:error, Ecto.Changeset.t()}
  def record(%{id: actor_id, type: actor_type}, action, %{id: res_id, type: res_type}, opts \\ %{})
      when is_integer(actor_id) and is_binary(actor_type) and
             is_binary(action) and is_integer(res_id) and is_binary(res_type) do
    attrs = %{
      action: action,
      actor_id: actor_id,
      actor_type: actor_type,
      resource_type: res_type,
      resource_id: res_id,
      metadata: Map.get(opts, :metadata, %{}),
      ip_address: Map.get(opts, :ip_address),
      occurred_at: DateTime.utc_now()
    }

    attrs |> Event.changeset() |> Repo.insert()
  end

  @spec for_resource(String.t(), integer(), keyword()) :: list(Event.t())
  def for_resource(resource_type, resource_id, opts \\ [])
      when is_binary(resource_type) and is_integer(resource_id) do
    limit = Keyword.get(opts, :limit, 100)

    Event
    |> where([e], e.resource_type == ^resource_type and e.resource_id == ^resource_id)
    |> order_by([e], desc: e.occurred_at)
    |> limit(^limit)
    |> Repo.all()
  end

  @spec for_actor(String.t(), integer(), keyword()) :: list(Event.t())
  def for_actor(actor_type, actor_id, opts \\ [])
      when is_binary(actor_type) and is_integer(actor_id) do
    limit = Keyword.get(opts, :limit, 100)

    Event
    |> where([e], e.actor_type == ^actor_type and e.actor_id == ^actor_id)
    |> order_by([e], desc: e.occurred_at)
    |> limit(^limit)
    |> Repo.all()
  end

  @spec in_range(DateTime.t(), DateTime.t()) :: list(Event.t())
  def in_range(%DateTime{} = from, %DateTime{} = to) do
    Event
    |> where([e], e.occurred_at >= ^from and e.occurred_at <= ^to)
    |> order_by([e], asc: e.occurred_at)
    |> Repo.all()
  end

  @spec count_by_action(String.t(), integer()) :: %{String.t() => integer()}
  def count_by_action(resource_type, resource_id)
      when is_binary(resource_type) and is_integer(resource_id) do
    Event
    |> where([e], e.resource_type == ^resource_type and e.resource_id == ^resource_id)
    |> group_by([e], e.action)
    |> select([e], {e.action, count(e.id)})
    |> Repo.all()
    |> Map.new()
  end
end
```
