**File:** `example_good_1406.md`

```elixir
defmodule ReadCache.Loader do
  @moduledoc "Behaviour for read-through cache loaders."

  @doc """
  Fetches the value for the given key from the underlying data source.
  Returns {:ok, value} or {:error, reason}.
  """
  @callback load(term()) :: {:ok, term()} | {:error, term()}
end

defmodule ReadCache.CacheEntry do
  @moduledoc "Internal entry stored in the cache table."

  @enforce_keys [:value, :expires_at]
  defstruct [:value, :expires_at]

  @type t :: %__MODULE__{value: term(), expires_at: integer()}

  @spec live?(t()) :: boolean()
  def live?(%__MODULE__{expires_at: exp}) do
    System.monotonic_time(:millisecond) < exp
  end
end

defmodule ReadCache do
  @moduledoc """
  A GenServer-managed ETS-backed read-through cache. On a miss, the
  configured loader module is called and the result is stored with a TTL.
  Concurrent requests for the same missing key are coalesced via caller
  queuing so the loader is only invoked once per key.
  """

  use GenServer

  alias ReadCache.{CacheEntry, Loader}

  @default_ttl_ms :timer.minutes(10)

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @spec get(term(), keyword()) :: {:ok, term()} | {:error, term()}
  def get(key, opts \\ []) do
    server = Keyword.get(opts, :server, __MODULE__)
    GenServer.call(server, {:get, key}, :timer.seconds(15))
  end

  @spec invalidate(term(), keyword()) :: :ok
  def invalidate(key, opts \\ []) do
    server = Keyword.get(opts, :server, __MODULE__)
    GenServer.call(server, {:invalidate, key})
  end

  @spec flush(keyword()) :: :ok
  def flush(opts \\ []) do
    server = Keyword.get(opts, :server, __MODULE__)
    GenServer.call(server, :flush)
  end

  @impl GenServer
  def init(opts) do
    table = :ets.new(:read_cache, [:set, :private])

    state = %{
      table: table,
      loader: Keyword.fetch!(opts, :loader),
      ttl_ms: Keyword.get(opts, :ttl_ms, @default_ttl_ms),
      pending: %{}
    }

    {:ok, state}
  end

  @impl GenServer
  def handle_call({:get, key}, from, state) do
    case ets_lookup(state.table, key) do
      {:ok, value} ->
        {:reply, {:ok, value}, state}

      :miss ->
        new_state = enqueue_or_load(key, from, state)
        {:noreply, new_state}
    end
  end

  def handle_call({:invalidate, key}, _from, state) do
    :ets.delete(state.table, key)
    {:reply, :ok, state}
  end

  def handle_call(:flush, _from, state) do
    :ets.delete_all_objects(state.table)
    {:reply, :ok, state}
  end

  @impl GenServer
  def handle_info({:loaded, key, result}, state) do
    waiters = Map.get(state.pending, key, [])

    case result do
      {:ok, value} ->
        expires_at = System.monotonic_time(:millisecond) + state.ttl_ms
        :ets.insert(state.table, {key, %CacheEntry{value: value, expires_at: expires_at}})
        Enum.each(waiters, &GenServer.reply(&1, {:ok, value}))

      {:error, _reason} = err ->
        Enum.each(waiters, &GenServer.reply(&1, err))
    end

    {:noreply, %{state | pending: Map.delete(state.pending, key)}}
  end

  defp ets_lookup(table, key) do
    case :ets.lookup(table, key) do
      [{^key, %CacheEntry{} = entry}] ->
        if CacheEntry.live?(entry), do: {:ok, entry.value}, else: :miss

      [] ->
        :miss
    end
  end

  defp enqueue_or_load(key, from, %{pending: pending} = state) do
    if Map.has_key?(pending, key) do
      %{state | pending: Map.update!(pending, key, &[from | &1])}
    else
      loader = state.loader
      self_pid = self()

      Task.start(fn ->
        result = loader.load(key)
        send(self_pid, {:loaded, key, result})
      end)

      %{state | pending: Map.put(pending, key, [from])}
    end
  end
end
```
