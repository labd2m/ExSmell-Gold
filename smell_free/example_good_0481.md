```elixir
defmodule Cache.L2Backend do
  @moduledoc """
  Behaviour for an external (L2) cache backend such as Redis or Memcached.
  """

  @callback get(key :: String.t()) :: {:ok, term()} | {:error, :not_found | term()}
  @callback put(key :: String.t(), value :: term(), ttl_seconds :: pos_integer()) :: :ok | {:error, term()}
  @callback delete(key :: String.t()) :: :ok
end

defmodule Cache.Composite do
  @moduledoc """
  A two-level cache that checks a fast in-process ETS store (L1) before
  falling through to a slower external backend (L2).

  On an L1 miss the L2 backend is consulted; a hit populates L1 for
  subsequent reads. L1 TTLs are kept shorter than L2 TTLs to ensure
  freshness without excessive L2 traffic. Both levels are invalidated
  on explicit `delete/2`.
  """

  use GenServer

  @type opts :: [
          name: atom(),
          l2_backend: module(),
          l1_ttl_seconds: pos_integer(),
          l2_ttl_seconds: pos_integer()
        ]

  @spec start_link(opts()) :: GenServer.on_start()
  def start_link(opts) do
    name = Keyword.fetch!(opts, :name)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @spec get(atom(), String.t()) :: {:ok, term()} | {:error, :not_found}
  def get(cache, key) when is_atom(cache) and is_binary(key) do
    table = l1_table(cache)

    case l1_get(table, key) do
      {:ok, value} ->
        {:ok, value}

      {:error, :not_found} ->
        GenServer.call(cache, {:l2_get, key})
    end
  end

  @spec put(atom(), String.t(), term()) :: :ok
  def put(cache, key, value) when is_atom(cache) and is_binary(key) do
    GenServer.call(cache, {:put, key, value})
  end

  @spec delete(atom(), String.t()) :: :ok
  def delete(cache, key) when is_atom(cache) and is_binary(key) do
    GenServer.cast(cache, {:delete, key})
  end

  @impl GenServer
  def init(opts) do
    name = Keyword.fetch!(opts, :name)
    table = l1_table(name)
    :ets.new(table, [:named_table, :public, read_concurrency: true])

    state = %{
      table: table,
      l2: Keyword.fetch!(opts, :l2_backend),
      l1_ttl: Keyword.get(opts, :l1_ttl_seconds, 60),
      l2_ttl: Keyword.get(opts, :l2_ttl_seconds, 600)
    }

    {:ok, state}
  end

  @impl GenServer
  def handle_call({:l2_get, key}, _from, state) do
    reply =
      case state.l2.get(key) do
        {:ok, value} ->
          l1_put(state.table, key, value, state.l1_ttl)
          {:ok, value}

        {:error, _} ->
          {:error, :not_found}
      end

    {:reply, reply, state}
  end

  def handle_call({:put, key, value}, _from, state) do
    l1_put(state.table, key, value, state.l1_ttl)
    state.l2.put(key, value, state.l2_ttl)
    {:reply, :ok, state}
  end

  @impl GenServer
  def handle_cast({:delete, key}, state) do
    :ets.delete(state.table, key)
    state.l2.delete(key)
    {:noreply, state}
  end

  defp l1_get(table, key) do
    now = System.system_time(:second)

    case :ets.lookup(table, key) do
      [{^key, value, expires_at}] when expires_at > now -> {:ok, value}
      _ -> {:error, :not_found}
    end
  end

  defp l1_put(table, key, value, ttl) do
    expires_at = System.system_time(:second) + ttl
    :ets.insert(table, {key, value, expires_at})
  end

  defp l1_table(name), do: :"#{name}_l1"
end
```
