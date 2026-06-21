```elixir
defmodule Platform.LruCache do
  @moduledoc """
  A Least-Recently-Used cache backed by two ETS tables: one for key-value
  storage and one for access-order tracking.

  Writes are serialized through the GenServer to maintain capacity invariants.
  Reads query ETS directly for concurrency, then asynchronously update the
  access order. Capacity eviction removes the least recently accessed entry.
  """

  use GenServer

  @type key :: term()
  @type value :: term()
  @type fetch_result :: {:ok, value()} | {:error, :not_found}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc "Fetches a value by key. Updates access time asynchronously on hit."
  @spec fetch(key()) :: fetch_result()
  def fetch(key) do
    table = :persistent_term.get({__MODULE__, :kv_table})

    case :ets.lookup(table, key) do
      [{^key, value}] ->
        GenServer.cast(__MODULE__, {:touch, key})
        {:ok, value}

      [] ->
        {:error, :not_found}
    end
  end

  @doc "Stores a key-value pair, evicting the LRU entry if at capacity."
  @spec put(key(), value()) :: :ok
  def put(key, value), do: GenServer.call(__MODULE__, {:put, key, value})

  @doc "Removes a key from the cache."
  @spec delete(key()) :: :ok
  def delete(key), do: GenServer.cast(__MODULE__, {:delete, key})

  @doc "Returns the current number of entries in the cache."
  @spec size() :: non_neg_integer()
  def size do
    :persistent_term.get({__MODULE__, :kv_table}) |> :ets.info(:size)
  end

  @impl GenServer
  def init(opts) do
    capacity = Keyword.fetch!(opts, :capacity)
    kv = :ets.new(:lru_kv, [:set, :public, read_concurrency: true])
    order = :ets.new(:lru_order, [:ordered_set, :private])
    :persistent_term.put({__MODULE__, :kv_table}, kv)

    {:ok, %{kv: kv, order: order, capacity: capacity, counter: 0, key_to_seq: %{}}}
  end

  @impl GenServer
  def handle_call({:put, key, value}, _from, state) do
    new_state = upsert(state, key, value)
    {:reply, :ok, new_state}
  end

  @impl GenServer
  def handle_cast({:touch, key}, state) do
    {:noreply, touch(state, key)}
  end

  @impl GenServer
  def handle_cast({:delete, key}, state) do
    {:noreply, remove(state, key)}
  end

  defp upsert(%{kv: kv, capacity: cap} = state, key, value) do
    state = if :ets.info(kv, :size) >= cap and not Map.has_key?(state.key_to_seq, key) do
      evict_lru(state)
    else
      state
    end

    :ets.insert(kv, {key, value})
    touch(state, key)
  end

  defp touch(%{order: order, counter: seq, key_to_seq: k2s} = state, key) do
    if old_seq = Map.get(k2s, key), do: :ets.delete(order, old_seq)
    new_seq = seq + 1
    :ets.insert(order, {new_seq, key})
    %{state | counter: new_seq, key_to_seq: Map.put(k2s, key, new_seq)}
  end

  defp evict_lru(%{order: order, kv: kv, key_to_seq: k2s} = state) do
    case :ets.first(order) do
      :"$end_of_table" ->
        state

      oldest_seq ->
        [{^oldest_seq, evict_key}] = :ets.lookup(order, oldest_seq)
        :ets.delete(order, oldest_seq)
        :ets.delete(kv, evict_key)
        %{state | key_to_seq: Map.delete(k2s, evict_key)}
    end
  end

  defp remove(%{order: order, kv: kv, key_to_seq: k2s} = state, key) do
    if seq = Map.get(k2s, key) do
      :ets.delete(order, seq)
      :ets.delete(kv, key)
      %{state | key_to_seq: Map.delete(k2s, key)}
    else
      state
    end
  end
end
```
