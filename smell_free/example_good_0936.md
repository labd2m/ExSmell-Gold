```elixir
defmodule Platform.CleanupWorker do
  @moduledoc """
  A GenServer that runs configurable cleanup tasks on a recurring schedule,
  removing expired records, temporary files, and stale sessions across the
  application.

  Each cleanup task is a named function that returns the count of items
  removed. Tasks run sequentially to avoid overwhelming the database,
  and results are emitted as Telemetry events for observability.
  """

  use GenServer

  require Logger

  @type task_name :: atom()
  @type task_fn :: (-> {:ok, non_neg_integer()} | {:error, term()})
  @type task_spec :: %{name: task_name(), fun: task_fn(), schedule_ms: pos_integer()}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc "Registers a cleanup task with a name, function, and interval."
  @spec register(task_name(), task_fn(), pos_integer()) :: :ok
  def register(name, fun, schedule_ms)
      when is_atom(name) and is_function(fun, 0) and is_integer(schedule_ms) do
    GenServer.cast(__MODULE__, {:register, name, fun, schedule_ms})
  end

  @doc "Triggers an immediate run of all registered tasks."
  @spec run_all() :: :ok
  def run_all, do: GenServer.cast(__MODULE__, :run_all)

  @doc "Returns the list of registered task names."
  @spec registered_tasks() :: [task_name()]
  def registered_tasks, do: GenServer.call(__MODULE__, :task_names)

  @impl GenServer
  def init(opts) do
    tasks = Keyword.get(opts, :tasks, []) |> Enum.map(&build_task/1)
    Enum.each(tasks, fn task -> schedule_task(task) end)
    {:ok, %{tasks: tasks}}
  end

  @impl GenServer
  def handle_cast({:register, name, fun, schedule_ms}, %{tasks: tasks} = state) do
    task = %{name: name, fun: fun, schedule_ms: schedule_ms}
    schedule_task(task)
    {:noreply, %{state | tasks: [task | tasks]}}
  end

  @impl GenServer
  def handle_cast(:run_all, %{tasks: tasks} = state) do
    Enum.each(tasks, &run_task/1)
    {:noreply, state}
  end

  @impl GenServer
  def handle_call(:task_names, _from, %{tasks: tasks} = state) do
    {:reply, Enum.map(tasks, & &1.name), state}
  end

  @impl GenServer
  def handle_info({:run_task, name}, %{tasks: tasks} = state) do
    case Enum.find(tasks, &(&1.name == name)) do
      nil ->
        {:noreply, state}

      task ->
        run_task(task)
        schedule_task(task)
        {:noreply, state}
    end
  end

  defp run_task(%{name: name, fun: fun}) do
    start = System.monotonic_time(:millisecond)
    Logger.debug("[CleanupWorker] Running task", task: name)

    result =
      try do
        fun.()
      rescue
        error -> {:error, error}
      end

    duration = System.monotonic_time(:millisecond) - start

    case result do
      {:ok, count} ->
        Logger.info("[CleanupWorker] Task complete", task: name, removed: count, duration_ms: duration)
        emit_telemetry(name, count, duration, :ok)

      {:error, reason} ->
        Logger.error("[CleanupWorker] Task failed", task: name, reason: inspect(reason), duration_ms: duration)
        emit_telemetry(name, 0, duration, :error)
    end
  end

  defp emit_telemetry(name, count, duration, status) do
    :telemetry.execute(
      [:platform, :cleanup, :task],
      %{duration_ms: duration, removed_count: count},
      %{task: name, status: status}
    )
  end

  defp schedule_task(%{name: name, schedule_ms: ms}) do
    Process.send_after(self(), {:run_task, name}, ms)
  end

  defp build_task({name, fun, schedule_ms}), do: %{name: name, fun: fun, schedule_ms: schedule_ms}
  defp build_task(%{} = task), do: task
end
```
