# File: `example_good_11.md`

```elixir
defmodule Cache.EtsStore do
  @moduledoc """
  ETS-backed key-value cache with per-entry TTL expiry.

  Entries are stored alongside their absolute expiry timestamp.
  Expired entries are evicted lazily on read and eagerly during
  periodic sweeps triggered by the owning GenServer.
  """

  use GenServer

  @table __MODULE__
  @sweep_interval_ms 30_000

  @type key :: term()
  @type value :: term()
  @type ttl_ms :: pos_integer()

  @doc false
  def start_link(_opts) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @doc """
  Fetches the value for `key` if it exists and has not expired.

  Returns `{:ok, value}` or `{:error, :miss}`.
  """
  @spec get(key()) :: {:ok, value()} | {:error, :miss}
  def get(key) do
    case :ets.lookup(@table, key) do
      [{^key, value, expires_at}] -> evaluate_entry(key, value, expires_at)
      [] -> {:error, :miss}
    end
  end

  @doc """
  Stores `value` under `key` with a TTL in milliseconds.

  Overwrites any existing value for `key`.
  """
  @spec put(key(), value(), ttl_ms()) :: :ok
  def put(key, value, ttl_ms) when is_integer(ttl_ms) and ttl_ms > 0 do
    expires_at = System.monotonic_time(:millisecond) + ttl_ms
    :ets.insert(@table, {key, value, expires_at})
    :ok
  end

  @doc """
  Removes the entry for `key` from the cache.

  Returns `:ok` regardless of whether the key existed.
  """
  @spec delete(key()) :: :ok
  def delete(key) do
    :ets.delete(@table, key)
    :ok
  end

  @doc """
  Fetches a value from the cache or populates it by calling `fun/0`
  if the key is absent or expired.

  The generated value is stored with `ttl_ms` and returned.
  Returns `{:ok, value}` or `{:error, :fetch_failed}` if `fun/0` raises.
  """
  @spec fetch_or_store(key(), ttl_ms(), (-> value())) ::
          {:ok, value()} | {:error, :fetch_failed}
  def fetch_or_store(key, ttl_ms, fun) when is_function(fun, 0) do
    case get(key) do
      {:ok, _value} = hit ->
        hit

      {:error, :miss} ->
        populate_cache(key, ttl_ms, fun)
    end
  end

  @doc """
  Returns the number of entries currently stored, including expired ones
  not yet swept.
  """
  @spec size() :: non_neg_integer()
  def size do
    :ets.info(@table, :size)
  end

  @doc """
  Immediately removes all expired entries from the cache.

  Returns the count of evicted entries.
  """
  @spec sweep() :: non_neg_integer()
  def sweep do
    GenServer.call(__MODULE__, :sweep)
  end

  @impl GenServer
  def init(_opts) do
    :ets.new(@table, [:named_table, :public, read_concurrency: true])
    schedule_sweep()
    {:ok, %{}}
  end

  @impl GenServer
  def handle_call(:sweep, _from, state) do
    count = evict_expired_entries()
    {:reply, count, state}
  end

  @impl GenServer
  def handle_info(:scheduled_sweep, state) do
    evict_expired_entries()
    schedule_sweep()
    {:noreply, state}
  end

  defp evaluate_entry(key, value, expires_at) do
    now = System.monotonic_time(:millisecond)

    if now < expires_at do
      {:ok, value}
    else
      :ets.delete(@table, key)
      {:error, :miss}
    end
  end

  defp populate_cache(key, ttl_ms, fun) do
    try do
      value = fun.()
      put(key, value, ttl_ms)
      {:ok, value}
    rescue
      _ -> {:error, :fetch_failed}
    end
  end

  defp evict_expired_entries do
    now = System.monotonic_time(:millisecond)
    match_spec = [{{:_, :_, :"$1"}, [{:<, :"$1", now}], [true]}]
    :ets.select_delete(@table, match_spec)
  end

  defp schedule_sweep do
    Process.send_after(self(), :scheduled_sweep, @sweep_interval_ms)
  end
end
```
