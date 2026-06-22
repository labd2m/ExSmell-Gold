```elixir
defmodule Scheduler.Job do
  @moduledoc """
  Represents a registered recurring job with its schedule and callback.
  """

  @type t :: %__MODULE__{
          name: atom(),
          interval_ms: pos_integer(),
          module: module(),
          function: atom(),
          args: list(),
          last_run_at: integer() | nil
        }

  defstruct [:name, :interval_ms, :module, :function, args: [], last_run_at: nil]
end

defmodule Scheduler do
  use GenServer

  alias Scheduler.Job

  @moduledoc """
  A lightweight in-process job scheduler that executes registered recurring
  tasks at configurable intervals. Each job is run in an isolated supervised
  Task to prevent a single failure from blocking the scheduling loop.
  """

  @tick_ms 1_000

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, :ok, Keyword.put(opts, :name, __MODULE__))
  end

  @spec register(Job.t()) :: :ok
  def register(%Job{} = job) do
    GenServer.cast(__MODULE__, {:register, job})
  end

  @spec deregister(atom()) :: :ok
  def deregister(job_name) when is_atom(job_name) do
    GenServer.cast(__MODULE__, {:deregister, job_name})
  end

  @spec list_jobs() :: [Job.t()]
  def list_jobs do
    GenServer.call(__MODULE__, :list_jobs)
  end

  @impl GenServer
  def init(:ok) do
    schedule_tick()
    {:ok, %{jobs: %{}}}
  end

  @impl GenServer
  def handle_cast({:register, job}, state) do
    {:noreply, put_in(state.jobs[job.name], job)}
  end

  def handle_cast({:deregister, name}, state) do
    {:noreply, %{state | jobs: Map.delete(state.jobs, name)}}
  end

  @impl GenServer
  def handle_call(:list_jobs, _from, state) do
    {:reply, Map.values(state.jobs), state}
  end

  @impl GenServer
  def handle_info(:tick, state) do
    now = System.monotonic_time(:millisecond)

    updated_jobs =
      state.jobs
      |> Enum.map(fn {name, job} ->
        job = maybe_run(job, now)
        {name, job}
      end)
      |> Map.new()

    schedule_tick()
    {:noreply, %{state | jobs: updated_jobs}}
  end

  defp maybe_run(%Job{last_run_at: nil} = job, now) do
    run_job(job)
    %{job | last_run_at: now}
  end

  defp maybe_run(%Job{last_run_at: last, interval_ms: interval} = job, now)
       when now - last >= interval do
    run_job(job)
    %{job | last_run_at: now}
  end

  defp maybe_run(job, _now), do: job

  defp run_job(%Job{module: mod, function: fun, args: args}) do
    Task.Supervisor.start_child(
      Scheduler.TaskSupervisor,
      fn -> apply(mod, fun, args) end
    )
  end

  defp schedule_tick do
    Process.send_after(self(), :tick, @tick_ms)
  end
end
```
