```elixir
defmodule MyApp.Cache do
  @moduledoc """
  A lightweight in-process TTL cache backed by an ETS table. Each entry
  carries an expiry timestamp; stale entries are evicted lazily on
  read and proactively by a periodic sweep.

  Suitable for caching hot reference data (feature flags, config tables,
  short-lived tokens) without adding a Redis dependency.

  Start this module under the application supervisor:

      children = [MyApp.Cache]
  """

  use GenServer

  @table __MODULE__
  @sweep_interval_ms 30_000
  @default_ttl_ms 60_000

  @type key :: term()
  @type value :: term()
  @type ttl_ms :: pos_integer()

  @doc "Starts the cache process and creates the backing ETS table."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Retrieves the value stored under `key`.
  Returns `{:ok, value}` or `{:error, :not_found}` when the key is absent
  or has expired.
  """
  @spec fetch(key()) :: {:ok, value()} | {:error, :not_found}
  def fetch(key) do
    now = System.monotonic_time(:millisecond)

    case :ets.lookup(@table, key) do
      [{^key, value, expires_at}] when expires_at > now -> {:ok, value}
      _ -> {:error, :not_found}
    end
  end

  @doc """
  Stores `value` under `key` with an optional TTL in milliseconds.
  Defaults to `#{@default_ttl_ms}` ms when no TTL is provided.
  """
  @spec put(key(), value(), ttl_ms()) :: :ok
  def put(key, value, ttl_ms \\ @default_ttl_ms) do
    expires_at = System.monotonic_time(:millisecond) + ttl_ms
    :ets.insert(@table, {key, value, expires_at})
    :ok
  end

  @doc "Removes the entry for `key` regardless of its expiry."
  @spec delete(key()) :: :ok
  def delete(key) do
    :ets.delete(@table, key)
    :ok
  end

  @doc """
  Returns the cached value if present, or calls `fallback_fn/0`, stores
  its result under `key` with the given TTL, and returns it.
  """
  @spec fetch_or_store(key(), (-> value()), ttl_ms()) :: {:ok, value()}
  def fetch_or_store(key, fallback_fn, ttl_ms \\ @default_ttl_ms)
      when is_function(fallback_fn, 0) do
    case fetch(key) do
      {:ok, _} = hit ->
        hit

      {:error, :not_found} ->
        value = fallback_fn.()
        put(key, value, ttl_ms)
        {:ok, value}
    end
  end

  @doc "Returns the number of entries currently live in the cache."
  @spec size() :: non_neg_integer()
  def size, do: :ets.info(@table, :size)

  @impl GenServer
  def init(_opts) do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    schedule_sweep()
    {:ok, %{}}
  end

  @impl GenServer
  def handle_info(:sweep, state) do
    evict_expired()
    schedule_sweep()
    {:noreply, state}
  end

  @spec evict_expired() :: non_neg_integer()
  defp evict_expired do
    now = System.monotonic_time(:millisecond)

    :ets.select_delete(@table, [
      {{:_, :_, :"$1"}, [{:"=<", :"$1", now}], [true]}
    ])
  end

  @spec schedule_sweep() :: reference()
  defp schedule_sweep,
    do: Process.send_after(self(), :sweep, @sweep_interval_ms)
end
```
