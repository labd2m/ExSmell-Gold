**File:** `example_good_1745.md`

```elixir
defmodule AuditLog.Entry do
  @moduledoc "Schema representing a single immutable audit log entry."

  use Ecto.Schema
  import Ecto.Changeset

  @type action :: :create | :update | :delete | :login | :logout | :export
  @type t :: %__MODULE__{
          id: Ecto.UUID.t() | nil,
          actor_id: String.t(),
          actor_type: String.t(),
          action: action(),
          resource_type: String.t(),
          resource_id: String.t() | nil,
          changes: map() | nil,
          ip_address: String.t() | nil,
          occurred_at: DateTime.t()
        }

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "audit_log_entries" do
    field :actor_id, :string
    field :actor_type, :string
    field :action, Ecto.Enum, values: [:create, :update, :delete, :login, :logout, :export]
    field :resource_type, :string
    field :resource_id, :string
    field :changes, :map
    field :ip_address, :string
    field :occurred_at, :utc_datetime_usec
  end

  @required_fields ~w(actor_id actor_type action resource_type occurred_at)a
  @optional_fields ~w(resource_id changes ip_address)a

  @spec changeset(map()) :: Ecto.Changeset.t()
  def changeset(attrs) do
    %__MODULE__{}
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_length(:actor_id, min: 1, max: 255)
    |> validate_length(:resource_type, min: 1, max: 128)
    |> validate_format(:ip_address, ~r/^\d{1,3}(\.\d{1,3}){3}$/, message: "must be a valid IPv4 address")
  end
end

defmodule AuditLog.Query do
  @moduledoc "Composable Ecto query helpers for filtering audit log entries."

  import Ecto.Query

  alias AuditLog.Entry

  @spec by_actor(Ecto.Query.t(), String.t()) :: Ecto.Query.t()
  def by_actor(query \\ Entry, actor_id) do
    where(query, [e], e.actor_id == ^actor_id)
  end

  @spec by_action(Ecto.Query.t(), Entry.action()) :: Ecto.Query.t()
  def by_action(query \\ Entry, action) do
    where(query, [e], e.action == ^action)
  end

  @spec by_resource(Ecto.Query.t(), String.t(), String.t() | nil) :: Ecto.Query.t()
  def by_resource(query \\ Entry, resource_type, resource_id \\ nil)

  def by_resource(query, resource_type, nil) do
    where(query, [e], e.resource_type == ^resource_type)
  end

  def by_resource(query, resource_type, resource_id) do
    where(query, [e], e.resource_type == ^resource_type and e.resource_id == ^resource_id)
  end

  @spec since(Ecto.Query.t(), DateTime.t()) :: Ecto.Query.t()
  def since(query \\ Entry, %DateTime{} = datetime) do
    where(query, [e], e.occurred_at >= ^datetime)
  end

  @spec most_recent_first(Ecto.Query.t()) :: Ecto.Query.t()
  def most_recent_first(query \\ Entry) do
    order_by(query, [e], desc: e.occurred_at)
  end

  @spec paginate(Ecto.Query.t(), pos_integer(), pos_integer()) :: Ecto.Query.t()
  def paginate(query, page, page_size) when page > 0 and page_size > 0 do
    query
    |> limit(^page_size)
    |> offset(^((page - 1) * page_size))
  end
end

defmodule AuditLog do
  @moduledoc """
  Public context for writing and querying the audit log.
  All entries are immutable once written.
  """

  import Ecto.Query, warn: false

  alias AuditLog.{Entry, Query}
  alias MyApp.Repo

  @type write_attrs :: %{
          required(:actor_id) => String.t(),
          required(:actor_type) => String.t(),
          required(:action) => Entry.action(),
          required(:resource_type) => String.t(),
          optional(:resource_id) => String.t(),
          optional(:changes) => map(),
          optional(:ip_address) => String.t()
        }

  @spec record(write_attrs()) :: {:ok, Entry.t()} | {:error, Ecto.Changeset.t()}
  def record(attrs) when is_map(attrs) do
    attrs
    |> Map.put_new(:occurred_at, DateTime.utc_now())
    |> Entry.changeset()
    |> Repo.insert()
  end

  @spec list_for_actor(String.t(), keyword()) :: [Entry.t()]
  def list_for_actor(actor_id, opts \\ []) do
    page = Keyword.get(opts, :page, 1)
    page_size = Keyword.get(opts, :page_size, 50)

    Entry
    |> Query.by_actor(actor_id)
    |> Query.most_recent_first()
    |> Query.paginate(page, page_size)
    |> Repo.all()
  end

  @spec list_for_resource(String.t(), String.t(), keyword()) :: [Entry.t()]
  def list_for_resource(resource_type, resource_id, opts \\ []) do
    page = Keyword.get(opts, :page, 1)
    page_size = Keyword.get(opts, :page_size, 50)

    Entry
    |> Query.by_resource(resource_type, resource_id)
    |> Query.most_recent_first()
    |> Query.paginate(page, page_size)
    |> Repo.all()
  end
end
```
