```elixir
defmodule Audit.Event do
  use Ecto.Schema
  import Ecto.Changeset

  @moduledoc """
  Immutable audit log entry recording who performed an action on what resource.
  Events are append-only; no update or delete operations are exposed.
  """

  @type action :: :created | :updated | :deleted | :exported | :login | :logout

  @type t :: %__MODULE__{
          id: Ecto.UUID.t(),
          actor_id: Ecto.UUID.t(),
          actor_email: String.t(),
          action: action(),
          resource_type: String.t(),
          resource_id: String.t() | nil,
          metadata: map(),
          occurred_at: DateTime.t()
        }

  @primary_key {:id, :binary_id, autogenerate: true}

  schema "audit_events" do
    field :actor_id, :binary_id
    field :actor_email, :string
    field :action, Ecto.Enum, values: [:created, :updated, :deleted, :exported, :login, :logout]
    field :resource_type, :string
    field :resource_id, :string
    field :metadata, :map, default: %{}
    field :occurred_at, :utc_datetime
  end

  @spec changeset(map()) :: Ecto.Changeset.t()
  def changeset(attrs) do
    %__MODULE__{}
    |> cast(attrs, [:actor_id, :actor_email, :action, :resource_type, :resource_id,
                    :metadata, :occurred_at])
    |> validate_required([:actor_id, :actor_email, :action, :resource_type, :occurred_at])
  end
end

defmodule Audit do
  import Ecto.Query

  alias Audit.Event
  alias MyApp.Repo

  @moduledoc """
  Public boundary for recording and querying the system audit trail.
  All writes are append-only to preserve historical integrity.
  """

  @type actor :: %{id: String.t(), email: String.t()}
  @type log_opts :: keyword()

  @spec log(actor(), Event.action(), String.t(), keyword()) ::
          {:ok, Event.t()} | {:error, Ecto.Changeset.t()}
  def log(%{id: actor_id, email: email}, action, resource_type, opts \\ [])
      when is_atom(action) and is_binary(resource_type) do
    attrs = %{
      actor_id: actor_id,
      actor_email: email,
      action: action,
      resource_type: resource_type,
      resource_id: Keyword.get(opts, :resource_id),
      metadata: Keyword.get(opts, :metadata, %{}),
      occurred_at: DateTime.utc_now() |> DateTime.truncate(:second)
    }

    attrs
    |> Event.changeset()
    |> Repo.insert()
  end

  @spec list_for_actor(String.t(), keyword()) :: [Event.t()]
  def list_for_actor(actor_id, opts \\ []) when is_binary(actor_id) do
    limit = Keyword.get(opts, :limit, 50)

    Event
    |> where([e], e.actor_id == ^actor_id)
    |> order_by([e], desc: e.occurred_at)
    |> limit(^limit)
    |> Repo.all()
  end

  @spec list_for_resource(String.t(), String.t(), keyword()) :: [Event.t()]
  def list_for_resource(resource_type, resource_id, opts \\ [])
      when is_binary(resource_type) and is_binary(resource_id) do
    limit = Keyword.get(opts, :limit, 50)

    Event
    |> where([e], e.resource_type == ^resource_type and e.resource_id == ^resource_id)
    |> order_by([e], desc: e.occurred_at)
    |> limit(^limit)
    |> Repo.all()
  end

  @spec since(DateTime.t(), keyword()) :: [Event.t()]
  def since(%DateTime{} = from, opts \\ []) do
    limit = Keyword.get(opts, :limit, 200)

    Event
    |> where([e], e.occurred_at >= ^from)
    |> order_by([e], asc: e.occurred_at)
    |> limit(^limit)
    |> Repo.all()
  end
end
```
