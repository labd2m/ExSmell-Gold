```elixir
defmodule Platform.JobScheduler do
  @moduledoc """
  A GenServer-based recurring job scheduler.

  Jobs are registered with a name, an interval, and a zero-arity function.
  The scheduler fires each job on its own independent timer, executes it
  asynchronously under a `Task.Supervisor`, and logs execution metadata.
  """

  use GenServer

  require Logger

  @type job_name :: atom()
  @type job_spec :: %{
          name: job_name(),
          interval_ms: pos_integer(),
          fun: (-> term())
        }
  @type state :: %{jobs: %{optional(job_name()) => job_spec()}, task_sup: Supervisor.supervisor()}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  Registers a recurring job. The `fun` is called every `interval_ms` milliseconds.
  Registering a job with the same name replaces the previous definition.
  """
  @spec register(job_name(), pos_integer(), (-> term())) :: :ok
  def register(name, interval_ms, fun)
      when is_atom(name) and is_integer(interval_ms) and interval_ms > 0 and is_function(fun, 0) do
    GenServer.cast(__MODULE__, {:register, name, interval_ms, fun})
  end

  @doc "Removes a previously registered job. A no-op if the job does not exist."
  @spec unregister(job_name()) :: :ok
  def unregister(name) when is_atom(name) do
    GenServer.cast(__MODULE__, {:unregister, name})
  end

  @doc "Returns the list of currently registered job names."
  @spec registered_jobs() :: [job_name()]
  def registered_jobs, do: GenServer.call(__MODULE__, :registered_jobs)

  @impl GenServer
  def init(opts) do
    task_sup = Keyword.get(opts, :task_supervisor, Platform.JobScheduler.TaskSupervisor)
    {:ok, %{jobs: %{}, task_sup: task_sup}}
  end

  @impl GenServer
  def handle_cast({:register, name, interval_ms, fun}, state) do
    job = %{name: name, interval_ms: interval_ms, fun: fun}
    schedule_job(job)
    {:noreply, put_in(state, [:jobs, name], job)}
  end

  @impl GenServer
  def handle_cast({:unregister, name}, state) do
    {:noreply, %{state | jobs: Map.delete(state.jobs, name)}}
  end

  @impl GenServer
  def handle_call(:registered_jobs, _from, state) do
    {:reply, Map.keys(state.jobs), state}
  end

  @impl GenServer
  def handle_info({:run_job, name}, %{jobs: jobs, task_sup: task_sup} = state) do
    case Map.get(jobs, name) do
      nil ->
        {:noreply, state}

      %{fun: fun, interval_ms: interval_ms} = job ->
        run_async(task_sup, name, fun)
        schedule_job(job)
        {:noreply, state}
    end
  end

  defp run_async(task_sup, name, fun) do
    Task.Supervisor.start_child(task_sup, fn ->
      start = System.monotonic_time(:millisecond)

      result =
        try do
          {:ok, fun.()}
        rescue
          error -> {:error, error}
        end

      duration = System.monotonic_time(:millisecond) - start
      log_result(name, result, duration)
    end)
  end

  defp log_result(name, {:ok, _}, duration) do
    Logger.info("[JobScheduler] Job completed", job: name, duration_ms: duration)
  end

  defp log_result(name, {:error, reason}, duration) do
    Logger.error("[JobScheduler] Job failed", job: name, reason: inspect(reason), duration_ms: duration)
  end

  defp schedule_job(%{name: name, interval_ms: interval_ms}) do
    Process.send_after(self(), {:run_job, name}, interval_ms)
  end
end
```
