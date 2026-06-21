```elixir
defmodule Platform.RequestCoalescer do
  @moduledoc """
  A GenServer that deduplicates concurrent requests for the same cache key.

  When multiple callers request the same resource simultaneously, only one
  upstream fetch is issued. All waiting callers receive the result once it
  resolves, avoiding redundant load on downstream services during cache misses
  or high-concurrency bursts.
  """

  use GenServer

  require Logger

  @type cache_key :: term()
  @type fetch_fn :: (-> {:ok, term()} | {:error, term()})
  @type result :: {:ok, term()} | {:error, term()}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  Fetches the value for `key` using `fetch_fn`, coalescing concurrent callers.

  If a fetch for `key` is already in progress, the caller blocks until that
  in-flight result resolves. Otherwise, `fetch_fn` is invoked once and its
  result is broadcast to all waiting callers.
  """
  @spec fetch(cache_key(), fetch_fn(), keyword()) :: result()
  def fetch(key, fetch_fn, opts \\ []) when is_function(fetch_fn, 0) do
    timeout = Keyword.get(opts, :timeout, 10_000)
    GenServer.call(__MODULE__, {:fetch, key, fetch_fn}, timeout)
  end

  @doc "Returns the set of keys currently being fetched."
  @spec in_flight_keys() :: [cache_key()]
  def in_flight_keys, do: GenServer.call(__MODULE__, :in_flight_keys)

  @impl GenServer
  def init(_opts) do
    {:ok, %{in_flight: %{}}}
  end

  @impl GenServer
  def handle_call({:fetch, key, fetch_fn}, from, %{in_flight: in_flight} = state) do
    case Map.get(in_flight, key) do
      nil ->
        task = Task.async(fn -> {key, fetch_fn.()} end)
        waiters = [from]
        {:noreply, %{state | in_flight: Map.put(in_flight, key, {task, waiters})}}

      {_task, waiters} ->
        new_waiters = [from | waiters]
        {:noreply, %{state | in_flight: Map.put(in_flight, key, {_task, new_waiters})}}
    end
  end

  @impl GenServer
  def handle_call(:in_flight_keys, _from, state) do
    {:reply, Map.keys(state.in_flight), state}
  end

  @impl GenServer
  def handle_info({ref, {key, result}}, %{in_flight: in_flight} = state) when is_reference(ref) do
    Process.demonitor(ref, [:flush])

    case Map.get(in_flight, key) do
      nil ->
        {:noreply, state}

      {_task, waiters} ->
        log_resolution(key, result, length(waiters))
        Enum.each(waiters, &GenServer.reply(&1, result))
        {:noreply, %{state | in_flight: Map.delete(in_flight, key)}}
    end
  end

  @impl GenServer
  def handle_info({:DOWN, _ref, :process, _pid, reason}, %{in_flight: in_flight} = state) do
    failed_key = Enum.find_value(in_flight, fn {key, {task, _}} ->
      if Process.info(task.pid) == nil, do: key
    end)

    case failed_key && Map.get(in_flight, failed_key) do
      nil ->
        {:noreply, state}

      {_task, waiters} ->
        error = {:error, {:fetch_task_died, reason}}
        Enum.each(waiters, &GenServer.reply(&1, error))
        {:noreply, %{state | in_flight: Map.delete(in_flight, failed_key)}}
    end
  end

  defp log_resolution(key, {:ok, _}, waiter_count) do
    Logger.debug("[RequestCoalescer] Resolved", key: inspect(key), waiters: waiter_count)
  end

  defp log_resolution(key, {:error, reason}, waiter_count) do
    Logger.warning("[RequestCoalescer] Fetch failed", key: inspect(key), reason: inspect(reason), waiters: waiter_count)
  end
end
```
