```elixir
defmodule Session.Store do
  @moduledoc """
  A supervised GenServer that owns a named ETS table used as an
  in-process session store. Session entries carry an explicit expiry
  timestamp and are lazily evicted on access as well as periodically
  swept by a background timer. The store process is the sole writer,
  while any process may read directly from ETS for minimal contention.
  """

  use GenServer

  require Logger

  @table :session_store
  @sweep_interval_ms 120_000

  @type session_id :: binary()
  @type session_data :: map()
  @type session_opts :: [ttl_seconds: pos_integer()]

  @default_ttl_seconds 3_600

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Stores `data` under a newly generated session ID.
  Returns `{:ok, session_id}`.
  """
  @spec create(session_data(), session_opts()) :: {:ok, session_id()}
  def create(data, opts \\ []) when is_map(data) do
    ttl = Keyword.get(opts, :ttl_seconds, @default_ttl_seconds)
    GenServer.call(__MODULE__, {:create, data, ttl})
  end

  @doc """
  Returns `{:ok, session_data}` for a valid, unexpired session, or
  `{:error, :not_found}` if the session is absent or expired.
  Accessing a session resets its TTL.
  """
  @spec fetch(session_id()) :: {:ok, session_data()} | {:error, :not_found}
  def fetch(session_id) when is_binary(session_id) do
    case :ets.lookup(@table, session_id) do
      [{^session_id, data, expires_at}] ->
        if unix_now() < expires_at do
          GenServer.cast(__MODULE__, {:touch, session_id, expires_at})
          {:ok, data}
        else
          GenServer.cast(__MODULE__, {:delete, session_id})
          {:error, :not_found}
        end

      [] ->
        {:error, :not_found}
    end
  end

  @doc """
  Merges `updates` into the data of an existing session.
  Returns `:ok` or `{:error, :not_found}`.
  """
  @spec update(session_id(), session_data()) :: :ok | {:error, :not_found}
  def update(session_id, updates) when is_binary(session_id) and is_map(updates) do
    GenServer.call(__MODULE__, {:update, session_id, updates})
  end

  @doc """
  Destroys the session immediately.
  """
  @spec destroy(session_id()) :: :ok
  def destroy(session_id) when is_binary(session_id) do
    GenServer.cast(__MODULE__, {:delete, session_id})
  end

  # ---------------------------------------------------------------------------
  # GenServer callbacks
  # ---------------------------------------------------------------------------

  @impl GenServer
  def init(_opts) do
    :ets.new(@table, [:named_table, :set, :public, read_concurrency: true])
    schedule_sweep()
    {:ok, %{}}
  end

  @impl GenServer
  def handle_call({:create, data, ttl}, _from, state) do
    session_id = generate_id()
    expires_at = unix_now() + ttl
    :ets.insert(@table, {session_id, data, expires_at})
    {:reply, {:ok, session_id}, state}
  end

  def handle_call({:update, session_id, updates}, _from, state) do
    case :ets.lookup(@table, session_id) do
      [{^session_id, data, expires_at}] when unix_now() < expires_at ->
        :ets.insert(@table, {session_id, Map.merge(data, updates), expires_at})
        {:reply, :ok, state}

      _ ->
        {:reply, {:error, :not_found}, state}
    end
  end

  @impl GenServer
  def handle_cast({:touch, session_id, expires_at}, state) do
    :ets.update_element(@table, session_id, {3, expires_at})
    {:noreply, state}
  end

  def handle_cast({:delete, session_id}, state) do
    :ets.delete(@table, session_id)
    {:noreply, state}
  end

  @impl GenServer
  def handle_info(:sweep, state) do
    now = unix_now()
    evicted = :ets.select_delete(@table, [{{:_, :_, :"$1"}, [{:<, :"$1", now}], [true]}])
    Logger.debug("Session sweep evicted #{evicted} expired sessions")
    schedule_sweep()
    {:noreply, state}
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp generate_id, do: :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)
  defp unix_now, do: System.system_time(:second)
  defp schedule_sweep, do: Process.send_after(self(), :sweep, @sweep_interval_ms)
end
```
