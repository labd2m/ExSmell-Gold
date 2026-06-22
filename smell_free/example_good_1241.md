```elixir
defmodule Infra.Cache.LayeredStore do
  @moduledoc """
  A two-layer cache: an in-process ETS L1 cache in front of a configurable
  L2 remote store. Cache misses in L1 are filled from L2, and L2 misses
  invoke a loader function. All TTLs are specified in seconds.
  """

  use GenServer

  @l1_table :layered_cache_l1
  @default_l1_ttl 60
  @sweep_interval_ms 30_000

  @type key :: String.t()
  @type loader :: (key() -> {:ok, term()} | {:error, term()})

  @doc """
  Starts the LayeredStore linked to the calling process.

  ## Options
    - `:l2` - module implementing the L2 cache behaviour (required)
    - `:l1_ttl` - L1 TTL in seconds (default: 60)
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Fetches `key` from the cache, invoking `loader` on a full miss.
  Returns `{:ok, value}` or `{:error, reason}`.
  """
  @spec fetch(key(), loader(), keyword()) :: {:ok, term()} | {:error, term()}
  def fetch(key, loader, opts \\ [])
      when is_binary(key) and is_function(loader, 1) do
    case l1_get(key) do
      {:ok, value} ->
        {:ok, value}

      :miss ->
        GenServer.call(__MODULE__, {:fetch_through, key, loader, opts})
    end
  end

  @doc """
  Explicitly invalidates `key` from both L1 and L2.
  """
  @spec invalidate(key()) :: :ok
  def invalidate(key) when is_binary(key) do
    :ets.delete(@l1_table, key)
    GenServer.cast(__MODULE__, {:invalidate_l2, key})
  end

  @impl GenServer
  def init(opts) do
    :ets.new(@l1_table, [:named_table, :public, read_concurrency: true])
    l2 = Keyword.fetch!(opts, :l2)
    l1_ttl = Keyword.get(opts, :l1_ttl, @default_l1_ttl)
    schedule_sweep()
    {:ok, %{l2: l2, l1_ttl: l1_ttl}}
  end

  @impl GenServer
  def handle_call({:fetch_through, key, loader, _opts}, _from, state) do
    result =
      case state.l2.get(key) do
        {:ok, value} ->
          l1_put(key, value, state.l1_ttl)
          {:ok, value}

        :miss ->
          case loader.(key) do
            {:ok, value} ->
              state.l2.put(key, value)
              l1_put(key, value, state.l1_ttl)
              {:ok, value}

            {:error, _} = err ->
              err
          end
      end

    {:reply, result, state}
  end

  @impl GenServer
  def handle_cast({:invalidate_l2, key}, state) do
    state.l2.delete(key)
    {:noreply, state}
  end

  @impl GenServer
  def handle_info(:sweep_l1, state) do
    now = System.system_time(:second)
    :ets.select_delete(@l1_table, [{{:_, :_, :"$1"}, [{:<, :"$1", now}], [true]}])
    schedule_sweep()
    {:noreply, state}
  end

  defp l1_get(key) do
    case :ets.lookup(@l1_table, key) do
      [{^key, value, exp}] ->
        if System.system_time(:second) < exp, do: {:ok, value}, else: :miss

      [] ->
        :miss
    end
  end

  defp l1_put(key, value, ttl) do
    exp = System.system_time(:second) + ttl
    :ets.insert(@l1_table, {key, value, exp})
  end

  defp schedule_sweep, do: Process.send_after(self(), :sweep_l1, @sweep_interval_ms)
end
```
