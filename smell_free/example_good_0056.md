```elixir
defmodule Cache.TTL do
  @moduledoc """
  A time-to-live in-memory cache backed by a GenServer. Each entry carries
  an expiration timestamp. A background sweep periodically removes entries
  that have passed their TTL. The cache name, default TTL, and sweep interval
  are all configurable at start time.
  """

  use GenServer

  @type key :: term()
  @type value :: term()
  @type entry :: %{value: value(), expires_at: integer()}

  @default_ttl_ms 60_000
  @sweep_interval_ms 30_000

  @doc "Starts the cache, registering it under the provided `:name` option."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "Stores `value` under `key`. Accepts an optional `ttl_ms` override."
  @spec put(GenServer.server(), key(), value(), keyword()) :: :ok
  def put(server \\ __MODULE__, key, value, opts \\ []) do
    ttl = Keyword.get(opts, :ttl_ms, @default_ttl_ms)
    GenServer.cast(server, {:put, key, value, ttl})
  end

  @doc """
  Retrieves a value by key. Returns `{:error, :not_found}` for absent or
  expired keys.
  """
  @spec get(GenServer.server(), key()) :: {:ok, value()} | {:error, :not_found}
  def get(server \\ __MODULE__, key) do
    GenServer.call(server, {:get, key})
  end

  @doc "Removes an entry from the cache."
  @spec delete(GenServer.server(), key()) :: :ok
  def delete(server \\ __MODULE__, key) do
    GenServer.cast(server, {:delete, key})
  end

  @doc "Returns the count of non-expired entries currently in the cache."
  @spec size(GenServer.server()) :: non_neg_integer()
  def size(server \\ __MODULE__) do
    GenServer.call(server, :size)
  end

  @impl GenServer
  def init(opts) do
    sweep_interval = Keyword.get(opts, :sweep_interval_ms, @sweep_interval_ms)
    Process.send_after(self(), :sweep, sweep_interval)
    {:ok, %{entries: %{}, sweep_interval: sweep_interval}}
  end

  @impl GenServer
  def handle_cast({:put, key, value, ttl}, state) do
    entry = %{value: value, expires_at: now() + ttl}
    {:noreply, put_in(state, [:entries, key], entry)}
  end

  def handle_cast({:delete, key}, state) do
    {:noreply, update_in(state, [:entries], &Map.delete(&1, key))}
  end

  @impl GenServer
  def handle_call({:get, key}, _from, state) do
    result =
      case Map.get(state.entries, key) do
        nil -> {:error, :not_found}
        %{expires_at: exp, value: val} ->
          if exp > now(), do: {:ok, val}, else: {:error, :not_found}
      end

    {:reply, result, state}
  end

  def handle_call(:size, _from, state) do
    current = now()
    count = Enum.count(state.entries, fn {_k, e} -> e.expires_at > current end)
    {:reply, count, state}
  end

  @impl GenServer
  def handle_info(:sweep, %{sweep_interval: interval} = state) do
    current = now()
    live = Map.reject(state.entries, fn {_k, e} -> e.expires_at <= current end)
    Process.send_after(self(), :sweep, interval)
    {:noreply, %{state | entries: live}}
  end

  defp now, do: System.monotonic_time(:millisecond)
end
```
