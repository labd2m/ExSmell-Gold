```elixir
defmodule MyApp.Queue.PriorityWorker do
  @moduledoc """
  A GenServer that drains a priority work queue, processing high-priority
  items before normal-priority ones regardless of arrival order. The queue
  is maintained in-process using two FIFO queues — one per priority level
  — so no external dependency is required for prioritised local dispatch.

  Work items are executed in supervised `Task` processes so that a crashing
  item does not stall the queue.
  """

  use GenServer

  require Logger

  @task_sup MyApp.Queue.TaskSupervisor

  @type priority :: :high | :normal
  @type work_fn :: (-> term())

  @type state :: %{
          high: :queue.queue(),
          normal: :queue.queue(),
          running: non_neg_integer(),
          concurrency: pos_integer()
        }

  @doc "Starts the priority worker."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Enqueues `fun` at the given `priority`. Dispatches immediately if a
  concurrency slot is free; otherwise parks in the appropriate queue.
  """
  @spec enqueue(work_fn(), priority()) :: :ok
  def enqueue(fun, priority \\ :normal) when is_function(fun, 0) and priority in [:high, :normal] do
    GenServer.cast(__MODULE__, {:enqueue, fun, priority})
  end

  @doc "Returns the current queue depths and running count."
  @spec stats() :: %{high: non_neg_integer(), normal: non_neg_integer(), running: non_neg_integer()}
  def stats, do: GenServer.call(__MODULE__, :stats)

  @impl GenServer
  def init(opts) do
    state = %{
      high: :queue.new(),
      normal: :queue.new(),
      running: 0,
      concurrency: Keyword.get(opts, :concurrency, System.schedulers_online())
    }

    {:ok, state}
  end

  @impl GenServer
  def handle_cast({:enqueue, fun, priority}, state) do
    new_state = %{state | priority => :queue.in(fun, Map.get(state, priority))}
    {:noreply, dispatch_pending(new_state)}
  end

  @impl GenServer
  def handle_call(:stats, _from, state) do
    reply = %{
      high: :queue.len(state.high),
      normal: :queue.len(state.normal),
      running: state.running
    }

    {:reply, reply, state}
  end

  @impl GenServer
  def handle_info({:task_done, outcome}, state) do
    if outcome == :error, do: Logger.warning("priority_worker_task_failed")
    new_state = %{state | running: max(state.running - 1, 0)}
    {:noreply, dispatch_pending(new_state)}
  end

  @spec dispatch_pending(state()) :: state()
  defp dispatch_pending(state) when state.running >= state.concurrency, do: state

  defp dispatch_pending(state) do
    case dequeue_next(state) do
      {nil, state} ->
        state

      {fun, new_state} ->
        run_task(fun)
        dispatch_pending(%{new_state | running: new_state.running + 1})
    end
  end

  @spec dequeue_next(state()) :: {work_fn() | nil, state()}
  defp dequeue_next(state) do
    case :queue.out(state.high) do
      {{:value, fun}, rest} -> {fun, %{state | high: rest}}
      {:empty, _} ->
        case :queue.out(state.normal) do
          {{:value, fun}, rest} -> {fun, %{state | normal: rest}}
          {:empty, _} -> {nil, state}
        end
    end
  end

  @spec run_task(work_fn()) :: :ok
  defp run_task(fun) do
    caller = self()

    Task.Supervisor.start_child(@task_sup, fn ->
      try do
        fun.()
        send(caller, {:task_done, :ok})
      rescue
        _ -> send(caller, {:task_done, :error})
      end
    end)

    :ok
  end
end
```
