```elixir
defmodule Cache.TtlStore do
  @moduledoc """
  An in-memory key-value cache with per-entry TTL, backed by a GenServer.

  Entries are lazily evicted on read and eagerly swept on a configurable
  interval. Both the default TTL and the sweep interval are passed at
  startup through options rather than global application config.
  """

  use GenServer

  @type key :: term()
  @type value :: term()
  @type ttl_ms :: pos_integer()
  @type fetch_result :: {:ok, value()} | {:error, :not_found | :expired}

  @default_ttl_ms 60_000
  @default_sweep_ms 30_000

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  Fetches a value by key. Returns `{:error, :expired}` for stale entries
  and removes them from the store, or `{:error, :not_found}` for missing keys.
  """
  @spec fetch(key()) :: fetch_result()
  def fetch(key), do: GenServer.call(__MODULE__, {:fetch, key})

  @doc """
  Stores `value` under `key` with `ttl_ms` milliseconds until expiry.
  Overwrites any existing entry for that key.
  """
  @spec put(key(), value(), ttl_ms()) :: :ok
  def put(key, value, ttl_ms \\ @default_ttl_ms) when is_integer(ttl_ms) and ttl_ms > 0 do
    GenServer.cast(__MODULE__, {:put, key, value, ttl_ms})
  end

  @doc "Removes an entry by key. A no-op if the key is absent."
  @spec delete(key()) :: :ok
  def delete(key), do: GenServer.cast(__MODULE__, {:delete, key})

  @doc "Returns the current number of entries in the cache, including not-yet-swept stale ones."
  @spec size() :: non_neg_integer()
  def size, do: GenServer.call(__MODULE__, :size)

  @impl GenServer
  def init(opts) do
    interval = Keyword.get(opts, :sweep_interval_ms, @default_sweep_ms)
    schedule_sweep(interval)
    {:ok, %{store: %{}, sweep_interval: interval}}
  end

  @impl GenServer
  def handle_call({:fetch, key}, _from, state) do
    {reply, new_store} = lookup(state.store, key)
    {:reply, reply, %{state | store: new_store}}
  end

  @impl GenServer
  def handle_call(:size, _from, state) do
    {:reply, map_size(state.store), state}
  end

  @impl GenServer
  def handle_cast({:put, key, value, ttl_ms}, state) do
    entry = %{value: value, expires_at: now_ms() + ttl_ms}
    {:noreply, put_in(state, [:store, key], entry)}
  end

  @impl GenServer
  def handle_cast({:delete, key}, state) do
    {:noreply, %{state | store: Map.delete(state.store, key)}}
  end

  @impl GenServer
  def handle_info(:sweep, %{sweep_interval: interval} = state) do
    schedule_sweep(interval)
    {:noreply, %{state | store: evict_expired(state.store)}}
  end

  defp lookup(store, key) do
    case Map.get(store, key) do
      nil ->
        {{:error, :not_found}, store}

      %{value: value, expires_at: exp} ->
        if exp < now_ms() do
          {{:error, :expired}, Map.delete(store, key)}
        else
          {{:ok, value}, store}
        end
    end
  end

  defp evict_expired(store) do
    current = now_ms()
    Map.reject(store, fn {_key, %{expires_at: exp}} -> exp < current end)
  end

  defp schedule_sweep(interval), do: Process.send_after(self(), :sweep, interval)
  defp now_ms, do: :erlang.system_time(:millisecond)
end
```
