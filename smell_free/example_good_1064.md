**File:** `example_good_1064.md`

```elixir
defmodule Cache.Store do
  @moduledoc """
  In-process key-value cache with per-entry TTL eviction. Entries are stored
  in an ETS table for concurrent read access. A GenServer coordinates writes
  and scheduled expiry sweeps.
  """

  use GenServer

  @table :cache_store
  @sweep_interval_ms 10_000

  @type key :: term()
  @type value :: term()

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec get(key()) :: {:ok, value()} | :miss
  def get(key) do
    case :ets.lookup(@table, key) do
      [{^key, value, expires_at}] ->
        if System.monotonic_time(:millisecond) < expires_at do
          {:ok, value}
        else
          :miss
        end

      [] ->
        :miss
    end
  end

  @spec put(key(), value(), pos_integer()) :: :ok
  def put(key, value, ttl_ms) when is_integer(ttl_ms) and ttl_ms > 0 do
    GenServer.call(__MODULE__, {:put, key, value, ttl_ms})
  end

  @spec delete(key()) :: :ok
  def delete(key) do
    GenServer.call(__MODULE__, {:delete, key})
  end

  @spec flush() :: :ok
  def flush do
    GenServer.call(__MODULE__, :flush)
  end

  @spec stats() :: %{size: non_neg_integer(), memory_words: non_neg_integer()}
  def stats do
    size = :ets.info(@table, :size)
    memory = :ets.info(@table, :memory)
    %{size: size, memory_words: memory}
  end

  @impl GenServer
  def init(_opts) do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    schedule_sweep()
    {:ok, %{}}
  end

  @impl GenServer
  def handle_call({:put, key, value, ttl_ms}, _from, state) do
    expires_at = System.monotonic_time(:millisecond) + ttl_ms
    :ets.insert(@table, {key, value, expires_at})
    {:reply, :ok, state}
  end

  def handle_call({:delete, key}, _from, state) do
    :ets.delete(@table, key)
    {:reply, :ok, state}
  end

  def handle_call(:flush, _from, state) do
    :ets.delete_all_objects(@table)
    {:reply, :ok, state}
  end

  @impl GenServer
  def handle_info(:sweep, state) do
    evict_expired()
    schedule_sweep()
    {:noreply, state}
  end

  defp evict_expired do
    now = System.monotonic_time(:millisecond)
    match_spec = [{{:_, :_, :"$1"}, [{:<, :"$1", now}], [true]}]
    :ets.select_delete(@table, match_spec)
  end

  defp schedule_sweep do
    Process.send_after(self(), :sweep, @sweep_interval_ms)
  end
end

defmodule Cache.Supervisor do
  @moduledoc "Top-level supervisor for the cache subsystem."

  use Supervisor

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl Supervisor
  def init(_opts) do
    children = [Cache.Store]
    Supervisor.init(children, strategy: :one_for_one)
  end
end
```
