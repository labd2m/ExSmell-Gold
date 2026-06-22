**File:** `example_good_1168.md`

```elixir
defmodule Cache.Entry do
  @moduledoc "Represents a single cached value with an expiry timestamp."

  @enforce_keys [:key, :value, :expires_at]
  defstruct [:key, :value, :expires_at]

  @type t :: %__MODULE__{
          key: term(),
          value: term(),
          expires_at: integer()
        }

  @spec new(term(), term(), pos_integer()) :: t()
  def new(key, value, ttl_ms) do
    %__MODULE__{
      key: key,
      value: value,
      expires_at: System.monotonic_time(:millisecond) + ttl_ms
    }
  end

  @spec expired?(t()) :: boolean()
  def expired?(%__MODULE__{expires_at: exp}) do
    System.monotonic_time(:millisecond) >= exp
  end
end

defmodule Cache.Store do
  @moduledoc """
  A GenServer that owns and manages an ETS table used as a local cache.
  Periodically evicts expired entries to reclaim memory.
  """

  use GenServer

  alias Cache.Entry

  @default_ttl_ms :timer.minutes(5)
  @eviction_interval_ms :timer.minutes(1)

  @type get_result :: {:ok, term()} | {:error, :not_found} | {:error, :expired}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @spec put(term(), term(), pos_integer()) :: :ok
  def put(key, value, ttl_ms \\ @default_ttl_ms) do
    GenServer.call(__MODULE__, {:put, key, value, ttl_ms})
  end

  @spec get(term()) :: get_result()
  def get(key) do
    case :ets.lookup(__MODULE__, key) do
      [{^key, %Entry{} = entry}] -> resolve_entry(entry)
      [] -> {:error, :not_found}
    end
  end

  @spec delete(term()) :: :ok
  def delete(key) do
    GenServer.call(__MODULE__, {:delete, key})
  end

  @spec flush() :: :ok
  def flush do
    GenServer.call(__MODULE__, :flush)
  end

  @impl GenServer
  def init(opts) do
    table = :ets.new(__MODULE__, [:named_table, :set, :public, read_concurrency: true])
    default_ttl = Keyword.get(opts, :default_ttl_ms, @default_ttl_ms)
    schedule_eviction()
    {:ok, %{table: table, default_ttl: default_ttl}}
  end

  @impl GenServer
  def handle_call({:put, key, value, ttl_ms}, _from, state) do
    entry = Entry.new(key, value, ttl_ms)
    :ets.insert(state.table, {key, entry})
    {:reply, :ok, state}
  end

  def handle_call({:delete, key}, _from, state) do
    :ets.delete(state.table, key)
    {:reply, :ok, state}
  end

  def handle_call(:flush, _from, state) do
    :ets.delete_all_objects(state.table)
    {:reply, :ok, state}
  end

  @impl GenServer
  def handle_info(:evict_expired, state) do
    evict_expired_entries(state.table)
    schedule_eviction()
    {:noreply, state}
  end

  defp resolve_entry(%Entry{} = entry) do
    if Entry.expired?(entry) do
      :ets.delete(__MODULE__, entry.key)
      {:error, :expired}
    else
      {:ok, entry.value}
    end
  end

  defp evict_expired_entries(table) do
    now = System.monotonic_time(:millisecond)

    :ets.select_delete(table, [
      {{:_, %{expires_at: :"$1"}}, [{:<, :"$1", now}], [true]}
    ])
  end

  defp schedule_eviction do
    Process.send_after(self(), :evict_expired, @eviction_interval_ms)
  end
end

defmodule Cache.Supervisor do
  @moduledoc "Supervises the cache store process."

  use Supervisor

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl Supervisor
  def init(opts) do
    children = [
      {Cache.Store, opts}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
```
