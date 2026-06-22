```elixir
defmodule Accounts.SessionManager do
  @moduledoc """
  Supervised GenServer managing the lifecycle of active user sessions.

  Sessions are stored in an ETS table for low-latency lookups and are
  evicted automatically based on configurable TTL. The process is registered
  under a stable name and is designed to be placed under an application
  supervisor.
  """

  use GenServer

  require Logger

  @table :active_sessions
  @default_ttl_seconds 3_600
  @sweep_interval_ms 60_000

  @type session_id :: String.t()
  @type session :: %{
          user_id: String.t(),
          issued_at: integer(),
          expires_at: integer(),
          metadata: map()
        }

  @doc """
  Starts the session manager as a named linked process.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Creates and stores a new session for the given user.

  Returns `{:ok, session_id}` with a freshly generated opaque session token.
  """
  @spec create_session(String.t(), map(), keyword()) :: {:ok, session_id()}
  def create_session(user_id, metadata \\ %{}, opts \\ []) when is_binary(user_id) do
    GenServer.call(__MODULE__, {:create, user_id, metadata, opts})
  end

  @doc """
  Fetches an active, non-expired session by its ID.

  Returns `{:error, :not_found}` for missing or expired sessions.
  """
  @spec fetch_session(session_id()) :: {:ok, session()} | {:error, :not_found}
  def fetch_session(session_id) when is_binary(session_id) do
    now = System.system_time(:second)

    case :ets.lookup(@table, session_id) do
      [{^session_id, session}] when session.expires_at > now -> {:ok, session}
      _ -> {:error, :not_found}
    end
  end

  @doc """
  Invalidates a session, immediately removing it from the active session store.
  """
  @spec revoke_session(session_id()) :: :ok
  def revoke_session(session_id) when is_binary(session_id) do
    GenServer.cast(__MODULE__, {:revoke, session_id})
  end

  @impl GenServer
  def init(opts) do
    :ets.new(@table, [:named_table, :public, read_concurrency: true])
    ttl = Keyword.get(opts, :ttl_seconds, @default_ttl_seconds)
    schedule_sweep()
    {:ok, %{ttl_seconds: ttl}}
  end

  @impl GenServer
  def handle_call({:create, user_id, metadata, opts}, _from, state) do
    session_id = generate_session_id()
    now = System.system_time(:second)
    ttl = Keyword.get(opts, :ttl_seconds, state.ttl_seconds)

    session = %{
      user_id: user_id,
      issued_at: now,
      expires_at: now + ttl,
      metadata: metadata
    }

    :ets.insert(@table, {session_id, session})
    Logger.debug("[SessionManager] Session created", user_id: user_id)
    {:reply, {:ok, session_id}, state}
  end

  @impl GenServer
  def handle_cast({:revoke, session_id}, state) do
    :ets.delete(@table, session_id)
    {:noreply, state}
  end

  @impl GenServer
  def handle_info(:sweep_expired, state) do
    now = System.system_time(:second)
    expired_count = sweep_expired_sessions(now)

    if expired_count > 0 do
      Logger.debug("[SessionManager] Swept expired sessions", count: expired_count)
    end

    schedule_sweep()
    {:noreply, state}
  end

  defp sweep_expired_sessions(now) do
    expired =
      :ets.tab2list(@table)
      |> Enum.filter(fn {_id, session} -> session.expires_at <= now end)
      |> Enum.map(fn {id, _} -> id end)

    Enum.each(expired, &:ets.delete(@table, &1))
    length(expired)
  end

  defp generate_session_id do
    :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)
  end

  defp schedule_sweep do
    Process.send_after(self(), :sweep_expired, @sweep_interval_ms)
  end
end
```
