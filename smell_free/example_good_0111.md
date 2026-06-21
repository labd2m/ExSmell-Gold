```elixir
defmodule Tasks.RecurringScheduler do
  @moduledoc """
  Schedules recurring named tasks at configurable intervals using
  `Process.send_after/3`. Each task definition holds its handler module
  and run interval. Task execution is delegated to supervised tasks so
  a slow or crashing handler never blocks the scheduler itself.
  """

  use GenServer

  require Logger

  @type task_def :: %{
          name: atom(),
          module: module(),
          interval_ms: pos_integer()
        }

  @type state :: %{tasks: [task_def()], supervisor: pid() | atom()}

  @doc "Starts the scheduler with the given task definitions."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Returns a list of registered task names and their next scheduled intervals."
  @spec registered_tasks() :: [%{name: atom(), interval_ms: pos_integer()}]
  def registered_tasks do
    GenServer.call(__MODULE__, :registered_tasks)
  end

  @impl GenServer
  def init(opts) do
    tasks = Keyword.get(opts, :tasks, [])
    supervisor = Keyword.get(opts, :task_supervisor, Tasks.TaskSupervisor)
    Enum.each(tasks, &schedule_first_run/1)
    {:ok, %{tasks: tasks, supervisor: supervisor}}
  end

  @impl GenServer
  def handle_call(:registered_tasks, _from, state) do
    summary = Enum.map(state.tasks, &Map.take(&1, [:name, :interval_ms]))
    {:reply, summary, state}
  end

  @impl GenServer
  def handle_info({:run_task, name}, state) do
    task_def = Enum.find(state.tasks, fn t -> t.name == name end)

    if task_def do
      dispatch_task(state.supervisor, task_def)
      reschedule(task_def)
    end

    {:noreply, state}
  end

  defp schedule_first_run(%{name: name, interval_ms: interval}) do
    Process.send_after(self(), {:run_task, name}, interval)
  end

  defp reschedule(%{name: name, interval_ms: interval}) do
    Process.send_after(self(), {:run_task, name}, interval)
  end

  defp dispatch_task(supervisor, %{name: name, module: mod}) do
    Task.Supervisor.start_child(supervisor, fn ->
      Logger.debug("[RecurringScheduler] Running task: #{name}")

      try do
        mod.run()
      rescue
        error -> Logger.error("[RecurringScheduler] Task #{name} raised: #{Exception.message(error)}")
      end
    end)
  end
end
```
