```elixir
defmodule Tasks.DependencyScheduler do
  @moduledoc """
  Schedules tasks that carry inter-task dependencies. Before a task is
  eligible for dispatch, all tasks it depends on must have completed
  successfully. The scheduler maintains a dependency graph and a
  per-task status map inside a GenServer. Workers report completion
  back to the scheduler so downstream tasks are automatically unlocked.
  """

  use GenServer

  require Logger

  @type task_id :: String.t()
  @type task_def :: %{
          id: task_id(),
          depends_on: [task_id()],
          payload: term()
        }
  @type task_status :: :waiting | :ready | :running | :done | :failed

  @type state :: %{
          tasks: %{task_id() => task_def()},
          statuses: %{task_id() => task_status()},
          dispatch_fn: (task_def() -> :ok)
        }

  @doc "Starts the dependency scheduler with a caller-supplied dispatch function."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc "Registers a list of tasks and immediately dispatches any that are ready."
  @spec load([task_def()]) :: :ok
  def load(task_defs) when is_list(task_defs) do
    GenServer.call(__MODULE__, {:load, task_defs})
  end

  @doc "Reports successful completion of `task_id`, unlocking dependants."
  @spec complete(task_id()) :: :ok
  def complete(task_id) when is_binary(task_id) do
    GenServer.cast(__MODULE__, {:complete, task_id})
  end

  @doc "Reports failure of `task_id`. Dependant tasks remain blocked."
  @spec fail(task_id()) :: :ok
  def fail(task_id) when is_binary(task_id) do
    GenServer.cast(__MODULE__, {:fail, task_id})
  end

  @doc "Returns the current status map for all registered tasks."
  @spec statuses() :: %{task_id() => task_status()}
  def statuses, do: GenServer.call(__MODULE__, :statuses)

  @impl GenServer
  def init(opts) do
    dispatch_fn = Keyword.fetch!(opts, :dispatch_fn)
    {:ok, %{tasks: %{}, statuses: %{}, dispatch_fn: dispatch_fn}}
  end

  @impl GenServer
  def handle_call({:load, task_defs}, _from, state) do
    new_tasks = Map.new(task_defs, fn t -> {t.id, t} end)
    initial_statuses = Map.new(task_defs, fn t -> {t.id, initial_status(t)} end)
    merged_tasks = Map.merge(state.tasks, new_tasks)
    merged_statuses = Map.merge(state.statuses, initial_statuses)
    new_state = %{state | tasks: merged_tasks, statuses: merged_statuses}
    dispatched_state = dispatch_ready(new_state)
    {:reply, :ok, dispatched_state}
  end

  def handle_call(:statuses, _from, state) do
    {:reply, state.statuses, state}
  end

  @impl GenServer
  def handle_cast({:complete, task_id}, state) do
    new_statuses = Map.put(state.statuses, task_id, :done)
    new_state = dispatch_ready(%{state | statuses: new_statuses})
    {:noreply, new_state}
  end

  def handle_cast({:fail, task_id}, state) do
    new_statuses = Map.put(state.statuses, task_id, :failed)
    {:noreply, %{state | statuses: new_statuses}}
  end

  defp initial_status(%{depends_on: []}), do: :ready
  defp initial_status(%{depends_on: _}), do: :waiting

  defp dispatch_ready(%{tasks: tasks, statuses: statuses, dispatch_fn: dispatch_fn} = state) do
    newly_ready =
      tasks
      |> Map.values()
      |> Enum.filter(fn t ->
        Map.get(statuses, t.id) == :waiting and
          Enum.all?(t.depends_on, fn dep -> Map.get(statuses, dep) == :done end)
      end)

    Enum.reduce(newly_ready, state, fn task, acc ->
      Logger.info("[DependencyScheduler] Dispatching task #{task.id}")
      dispatch_fn.(task)
      updated_statuses = Map.put(acc.statuses, task.id, :running)
      %{acc | statuses: updated_statuses}
    end)
  end
end
```
