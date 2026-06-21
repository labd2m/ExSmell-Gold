```elixir
defmodule MyApp.Compliance.AuditLogger do
  @moduledoc """
  Appends structured audit log entries to the `audit_log` table. Every
  mutation in the system that affects sensitive resources (user accounts,
  payment methods, admin configuration) should pass through this module.

  Writes are fire-and-forget casts to a supervised GenServer so that a
  slow database write never blocks the calling request process. Failures
  are logged and counted via telemetry rather than surfaced to callers.
  """

  use GenServer

  require Logger

  alias MyApp.Repo
  alias MyApp.Compliance.AuditEntry

  @type actor :: %{id: String.t(), type: :user | :system | :admin}
  @type resource :: %{id: String.t(), type: String.t()}
  @type action :: String.t()
  @type metadata :: map()

  @doc "Starts the audit logger process."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Enqueues an audit log entry. Returns `:ok` immediately; the write
  happens asynchronously in the logger process.
  """
  @spec log(actor(), action(), resource(), metadata()) :: :ok
  def log(actor, action, resource, metadata \\ %{})
      when is_map(actor) and is_binary(action) and is_map(resource) do
    entry = %{
      actor_id: actor.id,
      actor_type: actor.type,
      action: action,
      resource_id: resource.id,
      resource_type: resource.type,
      metadata: metadata,
      occurred_at: DateTime.utc_now()
    }

    GenServer.cast(__MODULE__, {:write, entry})
  end

  @impl GenServer
  def init(_opts), do: {:ok, %{}}

  @impl GenServer
  def handle_cast({:write, entry}, state) do
    persist(entry)
    {:noreply, state}
  end

  @spec persist(map()) :: :ok
  defp persist(entry) do
    result =
      %AuditEntry{}
      |> AuditEntry.changeset(entry)
      |> Repo.insert()

    case result do
      {:ok, _} ->
        emit_telemetry(:success, entry.action)

      {:error, changeset} ->
        Logger.error("audit_log_write_failed",
          action: entry.action,
          errors: inspect(changeset.errors)
        )

        emit_telemetry(:failure, entry.action)
    end
  end

  @spec emit_telemetry(:success | :failure, action()) :: :ok
  defp emit_telemetry(outcome, action) do
    :telemetry.execute(
      [:my_app, :audit_log, :write],
      %{count: 1},
      %{outcome: outcome, action: action}
    )
  end
end

defmodule MyApp.Compliance.AuditEntry do
  @moduledoc "Ecto schema for a single immutable audit log record."

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}

  schema "audit_log" do
    field :actor_id, :string
    field :actor_type, Ecto.Enum, values: [:user, :system, :admin]
    field :action, :string
    field :resource_id, :string
    field :resource_type, :string
    field :metadata, :map, default: %{}
    field :occurred_at, :utc_datetime

    timestamps(updated_at: false, type: :utc_datetime)
  end

  @spec changeset(__MODULE__.t(), map()) :: Ecto.Changeset.t()
  def changeset(entry, attrs) do
    entry
    |> cast(attrs, [:actor_id, :actor_type, :action, :resource_id, :resource_type,
                    :metadata, :occurred_at])
    |> validate_required([:actor_id, :actor_type, :action, :resource_id,
                          :resource_type, :occurred_at])
    |> validate_length(:action, min: 1, max: 100)
  end
end
```
