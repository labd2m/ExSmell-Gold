```elixir
defmodule Auth.Session do
  @enforce_keys [:id, :user_id, :created_at, :expires_at, :permissions]
  defstruct [
    :id,
    :user_id,
    :created_at,
    :expires_at,
    :ip_address,
    :user_agent,
    :permissions,
    :mfa_verified,
    :audit_trail
  ]

  @type permission :: %{resource: String.t(), actions: [String.t()], conditions: map()}

  @type audit_entry :: %{
          event: String.t(),
          timestamp: DateTime.t(),
          ip: String.t(),
          metadata: map()
        }

  @type t :: %__MODULE__{
          id: String.t(),
          user_id: String.t(),
          created_at: DateTime.t(),
          expires_at: DateTime.t(),
          ip_address: String.t() | nil,
          user_agent: String.t() | nil,
          permissions: [permission()],
          mfa_verified: boolean(),
          audit_trail: [audit_entry()]
        }
end

defmodule Auth.SessionStore do
  use GenServer

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  def start_link(_), do: GenServer.start_link(__MODULE__, %{}, name: __MODULE__)

  def put(session), do: GenServer.cast(__MODULE__, {:put, session})

  def get(session_id), do: GenServer.call(__MODULE__, {:get, session_id})

  @doc "Returns the full session map – used for replication snapshots."
  def all, do: GenServer.call(__MODULE__, :all)

  # ---------------------------------------------------------------------------
  # Server callbacks
  # ---------------------------------------------------------------------------

  @impl true
  def init(_), do: {:ok, seed_sessions()}

  @impl true
  def handle_cast({:put, %Auth.Session{} = session}, state) do
    {:noreply, Map.put(state, session.id, session)}
  end

  @impl true
  def handle_call({:get, id}, _from, state) do
    {:reply, Map.get(state, id), state}
  end

  @impl true
  def handle_call(:all, _from, state) do
    {:reply, state, state}
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp seed_sessions do
    now = DateTime.utc_now()

    Map.new(1..50_000, fn n ->
      session = %Auth.Session{
        id: "sess_#{:crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)}",
        user_id: "usr_#{n}",
        created_at: now,
        expires_at: DateTime.add(now, 3600, :second),
        ip_address: "10.#{rem(n, 255)}.#{rem(n * 3, 255)}.#{rem(n * 7, 255)}",
        user_agent: "Mozilla/5.0 (compatible; App/2.0)",
        mfa_verified: rem(n, 2) == 0,
        permissions:
          Enum.map(1..30, fn p ->
            %{
              resource: "resource:#{rem(p, 10)}",
              actions: ["read", "write", "delete"],
              conditions: %{tenant: "t_#{rem(n, 50)}", env: "production"}
            }
          end),
        audit_trail:
          Enum.map(1..15, fn a ->
            %{
              event: Enum.random(["login", "token_refresh", "permission_check"]),
              timestamp: DateTime.add(now, -a * 300, :second),
              ip: "10.0.0.#{rem(a, 255)}",
              metadata: %{success: true, latency_ms: :rand.uniform(200)}
            }
          end)
      }

      {session.id, session}
    end)
  end
end

defmodule Auth.ReplicationWorker do
  use GenServer

  def start_link(opts), do: GenServer.start_link(__MODULE__, %{}, opts)

  @impl true
  def init(state), do: {:ok, state}

  @impl true
  def handle_info({:snapshot, sessions}, _state) do
    {:noreply, sessions}
  end
end

defmodule Auth.SessionManager do
  @moduledoc """
  Manages session lifecycle and orchestrates replication to standby nodes.
  """

  require Logger

  @doc """
  Sends a full snapshot of all active sessions to the standby replication worker.
  Called periodically by a scheduler to keep the standby in sync.
  """
  @spec replicate_snapshot(pid()) :: :ok
  def replicate_snapshot(standby_pid) do
    Logger.info("Preparing session snapshot for replication...")

    sessions = Auth.SessionStore.all()

    Logger.info("Snapshot contains #{map_size(sessions)} sessions. Sending to standby...")

    send(standby_pid, {:snapshot, sessions})

    Logger.info("Replication snapshot dispatched.")
    :ok
  end
end
```
