```elixir
defmodule Queue.PriorityWorker do
  @moduledoc """
  A GenServer that drains a three-level priority queue: `:high`, `:normal`,
  and `:low`. High-priority items are always processed before normal, and
  normal before low. Items are enqueued as tagged tuples and consumed by a
  caller-supplied handler function passed at start time.
  """

  use GenServer

  require Logger

  @type priority :: :high | :normal | :low
  @type item :: term()
  @type handler_fn :: (item() -> :ok | {:error, term()})

  @priorities [:high, :normal, :low]
  @poll_interval_ms 100

  @doc "Starts the priority worker with a handler function for processing items."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc "Enqueues `item` at the given `priority` level."
  @spec enqueue(GenServer.server(), priority(), item()) :: :ok
  def enqueue(server \\ __MODULE__, priority, item)
      when priority in [:high, :normal, :low] do
    GenServer.cast(server, {:enqueue, priority, item})
  end

  @doc "Returns the current queue depths as a map keyed by priority."
  @spec depths(GenServer.server()) :: %{priority() => non_neg_integer()}
  def depths(server \\ __MODULE__) do
    GenServer.call(server, :depths)
  end

  @impl GenServer
  def init(opts) do
    handler = Keyword.fetch!(opts, :handler)
    Process.send_after(self(), :drain, @poll_interval_ms)

    state = %{
      queues: Map.new(@priorities, fn p -> {p, :queue.new()} end),
      handler: handler
    }

    {:ok, state}
  end

  @impl GenServer
  def handle_cast({:enqueue, priority, item}, state) do
    new_queues = Map.update!(state.queues, priority, &:queue.in(item, &1))
    {:noreply, %{state | queues: new_queues}}
  end

  @impl GenServer
  def handle_call(:depths, _from, state) do
    depths = Map.new(state.queues, fn {p, q} -> {p, :queue.len(q)} end)
    {:reply, depths, state}
  end

  @impl GenServer
  def handle_info(:drain, state) do
    new_state = drain_one(state)
    Process.send_after(self(), :drain, @poll_interval_ms)
    {:noreply, new_state}
  end

  defp drain_one(%{queues: queues, handler: handler} = state) do
    case next_item(queues) do
      nil ->
        state

      {priority, item, updated_queues} ->
        invoke_handler(handler, item, priority)
        %{state | queues: updated_queues}
    end
  end

  defp next_item(queues) do
    Enum.find_value(@priorities, fn priority ->
      queue = Map.fetch!(queues, priority)
      case :queue.out(queue) do
        {{:value, item}, rest} -> {priority, item, Map.put(queues, priority, rest)}
        {:empty, _} -> nil
      end
    end)
  end

  defp invoke_handler(handler, item, priority) do
    case handler.(item) do
      :ok ->
        :ok
      {:error, reason} ->
        Logger.warning("[PriorityWorker] #{priority} item failed: #{inspect(reason)}")
    end
  rescue
    e -> Logger.error("[PriorityWorker] handler crashed: #{Exception.message(e)}")
  end
end
```
