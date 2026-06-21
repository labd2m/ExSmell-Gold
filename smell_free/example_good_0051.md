```elixir
defmodule Sessions.Store do
  @moduledoc """
  An in-memory session store backed by a GenServer. Sessions are keyed by
  a securely generated token and expire after a configurable TTL. A periodic
  sweep process removes expired entries without external intervention.
  All state mutations are encapsulated behind this module's public API.
  """

  use GenServer

  @type session_id :: String.t()
  @type session_data :: map()
  @type entry :: %{data: session_data(), expires_at: integer()}

  @default_ttl_seconds 3_600
  @sweep_interval_ms 60_000

  @doc "Starts the session store, registering it under its module name."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Creates a new session with the given data. Returns the generated session ID.
  Accepts an optional `ttl_seconds` override.
  """
  @spec create(session_data(), keyword()) :: {:ok, session_id()}
  def create(data, opts \\ []) when is_map(data) do
    ttl = Keyword.get(opts, :ttl_seconds, @default_ttl_seconds)
    GenServer.call(__MODULE__, {:create, data, ttl})
  end

  @doc """
  Fetches session data by ID. Returns `{:error, :not_found}` for missing
  sessions and `{:error, :expired}` for sessions past their TTL.
  """
  @spec fetch(session_id()) :: {:ok, session_data()} | {:error, :not_found | :expired}
  def fetch(session_id) when is_binary(session_id) do
    GenServer.call(__MODULE__, {:fetch, session_id})
  end

  @doc "Updates session data while preserving the original expiry timestamp."
  @spec update(session_id(), session_data()) :: :ok | {:error, :not_found}
  def update(session_id, data) when is_binary(session_id) and is_map(data) do
    GenServer.call(__MODULE__, {:update, session_id, data})
  end

  @doc "Explicitly invalidates a session. Safe to call even if not present."
  @spec invalidate(session_id()) :: :ok
  def invalidate(session_id) when is_binary(session_id) do
    GenServer.cast(__MODULE__, {:invalidate, session_id})
  end

  @impl GenServer
  def init(opts) do
    sweep_interval = Keyword.get(opts, :sweep_interval_ms, @sweep_interval_ms)
    Process.send_after(self(), :sweep, sweep_interval)
    {:ok, %{sessions: %{}, sweep_interval: sweep_interval}}
  end

  @impl GenServer
  def handle_call({:create, data, ttl}, _from, state) do
    session_id = generate_id()
    entry = %{data: data, expires_at: now() + ttl}
    new_state = put_in(state, [:sessions, session_id], entry)
    {:reply, {:ok, session_id}, new_state}
  end

  def handle_call({:fetch, session_id}, _from, state) do
    result = lookup(state.sessions, session_id)
    {:reply, result, state}
  end

  def handle_call({:update, session_id, data}, _from, state) do
    case Map.get(state.sessions, session_id) do
      nil ->
        {:reply, {:error, :not_found}, state}

      entry ->
        new_state = put_in(state, [:sessions, session_id], %{entry | data: data})
        {:reply, :ok, new_state}
    end
  end

  @impl GenServer
  def handle_cast({:invalidate, session_id}, state) do
    {:noreply, update_in(state, [:sessions], &Map.delete(&1, session_id))}
  end

  @impl GenServer
  def handle_info(:sweep, %{sweep_interval: interval} = state) do
    current = now()
    live = Map.reject(state.sessions, fn {_id, e} -> e.expires_at <= current end)
    Process.send_after(self(), :sweep, interval)
    {:noreply, %{state | sessions: live}}
  end

  defp lookup(sessions, id) do
    case Map.get(sessions, id) do
      nil -> {:error, :not_found}
      %{data: data, expires_at: exp} when exp > 0 ->
        if exp > now(), do: {:ok, data}, else: {:error, :expired}
    end
  end

  defp generate_id do
    :crypto.strong_rand_bytes(16) |> Base.url_encode64(padding: false)
  end

  defp now, do: System.os_time(:second)
end
```
