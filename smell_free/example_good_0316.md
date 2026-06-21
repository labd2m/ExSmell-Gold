```elixir
defmodule Cache.Lru do
  @moduledoc """
  A bounded, least-recently-used in-process cache backed by a public ETS table.

  Reads and existence checks hit the ETS table directly without serialising
  through the GenServer. Writes and evictions are serialised to keep the
  access-order index consistent. When the cache is at capacity, the entry
  with the oldest last-access timestamp is evicted to make room.
  """

  use GenServer

  @type key :: term()
  @type value :: term()
  @type opts :: [name: atom(), capacity: pos_integer(), ttl_seconds: pos_integer() | nil]

  @spec start_link(opts()) :: GenServer.on_start()
  def start_link(opts) do
    name = Keyword.fetch!(opts, :name)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @spec get(atom(), key()) :: {:ok, value()} | {:error, :not_found}
  def get(cache, key) do
    table = table_name(cache)

    case :ets.lookup(table, key) do
      [{^key, value, _inserted_at, expires_at}] ->
        if valid_at?(expires_at, System.system_time(:second)) do
          GenServer.cast(cache, {:touch, key})
          {:ok, value}
        else
          GenServer.cast(cache, {:evict, key})
          {:error, :not_found}
        end

      [] ->
        {:error, :not_found}
    end
  end

  @spec put(atom(), key(), value()) :: :ok
  def put(cache, key, value) do
    GenServer.call(cache, {:put, key, value})
  end

  @spec delete(atom(), key()) :: :ok
  def delete(cache, key) do
    GenServer.cast(cache, {:evict, key})
  end

  @spec size(atom()) :: non_neg_integer()
  def size(cache), do: :ets.info(table_name(cache), :size)

  @impl GenServer
  def init(opts) do
    name = Keyword.fetch!(opts, :name)
    table = table_name(name)
    :ets.new(table, [:named_table, :public, read_concurrency: true])

    state = %{
      table: table,
      capacity: Keyword.get(opts, :capacity, 1_000),
      ttl_seconds: Keyword.get(opts, :ttl_seconds, nil)
    }

    {:ok, state}
  end

  @impl GenServer
  def handle_call({:put, key, value}, _from, state) do
    now = System.system_time(:second)
    expires_at = if state.ttl_seconds, do: now + state.ttl_seconds, else: nil

    if :ets.info(state.table, :size) >= state.capacity do
      evict_oldest(state.table)
    end

    :ets.insert(state.table, {key, value, now, expires_at})
    {:reply, :ok, state}
  end

  @impl GenServer
  def handle_cast({:touch, key}, state) do
    case :ets.lookup(state.table, key) do
      [{^key, value, _old_ts, expires_at}] ->
        :ets.insert(state.table, {key, value, System.system_time(:second), expires_at})

      [] ->
        :ok
    end

    {:noreply, state}
  end

  def handle_cast({:evict, key}, state) do
    :ets.delete(state.table, key)
    {:noreply, state}
  end

  defp evict_oldest(table) do
    all = :ets.tab2list(table)

    case Enum.min_by(all, fn {_k, _v, inserted_at, _exp} -> inserted_at end, fn -> nil end) do
      nil -> :ok
      {oldest_key, _, _, _} -> :ets.delete(table, oldest_key)
    end
  end

  defp valid_at?(_expires_at = nil, _now), do: true
  defp valid_at?(expires_at, now), do: now < expires_at

  defp table_name(name), do: :"#{name}_lru_table"
end
```
