```elixir
defmodule Caching.TtlStore do
  @moduledoc """
  GenServer providing an in-memory key-value cache with per-entry
  time-to-live expiry.

  Entries are stored in ETS for concurrent reads without blocking the
  server process. Expiry is enforced lazily on read and proactively
  via a periodic sweep that removes stale entries from the table.
  """

  use GenServer

  @table :ttl_store_entries
  @sweep_interval_ms 30_000

  @type cache_key :: term()
  @type cache_value :: term()
  @type ttl_ms :: pos_integer()

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  Stores a value under the given key with an explicit TTL in milliseconds.
  Overwrites any existing entry for the same key.
  """
  @spec put(cache_key(), cache_value(), ttl_ms()) :: :ok
  def put(key, value, ttl_ms) when is_integer(ttl_ms) and ttl_ms > 0 do
    expires_at = System.monotonic_time(:millisecond) + ttl_ms
    :ets.insert(@table, {key, value, expires_at})
    :ok
  end

  @doc """
  Retrieves a value by key if it exists and has not expired.

  Returns `{:ok, value}` or `{:error, :not_found}`.
  """
  @spec get(cache_key()) :: {:ok, cache_value()} | {:error, :not_found}
  def get(key) do
    now = System.monotonic_time(:millisecond)

    case :ets.lookup(@table, key) do
      [{^key, value, expires_at}] when expires_at > now ->
        {:ok, value}

      [{^key, _value, _expired}] ->
        :ets.delete(@table, key)
        {:error, :not_found}

      [] ->
        {:error, :not_found}
    end
  end

  @doc """
  Deletes a cache entry by key regardless of expiry.
  """
  @spec delete(cache_key()) :: :ok
  def delete(key) do
    :ets.delete(@table, key)
    :ok
  end

  @doc """
  Returns the number of entries currently in the cache, including
  entries that may have expired but not yet been swept.
  """
  @spec size() :: non_neg_integer()
  def size do
    :ets.info(@table, :size)
  end

  @doc """
  Triggers an immediate sweep of expired entries.
  """
  @spec sweep() :: {:ok, non_neg_integer()}
  def sweep do
    GenServer.call(__MODULE__, :sweep)
  end

  @impl GenServer
  def init(opts) do
    :ets.new(@table, [:named_table, :set, :public, read_concurrency: true])
    sweep_interval = Keyword.get(opts, :sweep_interval_ms, @sweep_interval_ms)
    schedule_sweep(sweep_interval)
    {:ok, %{sweep_interval_ms: sweep_interval}}
  end

  @impl GenServer
  def handle_call(:sweep, _from, state) do
    count = do_sweep()
    {:reply, {:ok, count}, state}
  end

  @impl GenServer
  def handle_info(:scheduled_sweep, state) do
    do_sweep()
    schedule_sweep(state.sweep_interval_ms)
    {:noreply, state}
  end

  @spec do_sweep() :: non_neg_integer()
  defp do_sweep do
    now = System.monotonic_time(:millisecond)

    expired_keys =
      :ets.select(@table, [
        {{:"$1", :_, :"$2"}, [{:<, :"$2", now}], [:"$1"]}
      ])

    Enum.each(expired_keys, &:ets.delete(@table, &1))
    length(expired_keys)
  end

  @spec schedule_sweep(pos_integer()) :: reference()
  defp schedule_sweep(interval_ms) do
    Process.send_after(self(), :scheduled_sweep, interval_ms)
  end
end
```
