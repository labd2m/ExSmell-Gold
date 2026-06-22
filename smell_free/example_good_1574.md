```elixir
defmodule Scheduler.JobRunner do
  @moduledoc """
  Supervised GenServer that executes registered periodic jobs on configurable intervals.

  Jobs are registered at startup via the child spec options and run in isolated
  Tasks under a separate task supervisor to avoid blocking the runner's message loop.
  """

  use GenServer

  require Logger

  alias Scheduler.JobRunner.{Registry, JobSpec}

  @type init_opts :: [
          jobs: [JobSpec.t()],
          task_supervisor: module()
        ]

  @doc false
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl GenServer
  def init(opts) do
    jobs = Keyword.get(opts, :jobs, [])
    task_sup = Keyword.get(opts, :task_supervisor, Scheduler.TaskSupervisor)

    registry = Registry.build(jobs)
    schedule_all(registry)

    {:ok, %{registry: registry, task_supervisor: task_sup}}
  end

  @impl GenServer
  def handle_info({:run_job, job_name}, %{registry: registry, task_supervisor: task_sup} = state) do
    case Registry.fetch(registry, job_name) do
      {:ok, %JobSpec{interval_ms: interval, callback: cb}} ->
        Task.Supervisor.start_child(task_sup, fn -> execute_job(job_name, cb) end)
        Process.send_after(self(), {:run_job, job_name}, interval)

      :error ->
        Logger.warning("received tick for unknown job: #{inspect(job_name)}")
    end

    {:noreply, state}
  end

  defp schedule_all(registry) do
    registry
    |> Registry.all_specs()
    |> Enum.each(fn %JobSpec{name: name, interval_ms: ms} ->
      Process.send_after(self(), {:run_job, name}, ms)
    end)
  end

  defp execute_job(name, callback) do
    Logger.debug("running job #{inspect(name)}")
    callback.()
  rescue
    err ->
      Logger.error("job #{inspect(name)} failed: #{Exception.message(err)}")
  end
end

defmodule Scheduler.JobRunner.JobSpec do
  @moduledoc "Value object describing a scheduled job."

  @enforce_keys [:name, :interval_ms, :callback]
  defstruct [:name, :interval_ms, :callback]

  @type t :: %__MODULE__{
          name: atom(),
          interval_ms: pos_integer(),
          callback: (() -> any())
        }

  @spec new(atom(), pos_integer(), (() -> any())) :: t()
  def new(name, interval_ms, callback)
      when is_atom(name) and is_integer(interval_ms) and interval_ms > 0 and is_function(callback, 0) do
    %__MODULE__{name: name, interval_ms: interval_ms, callback: callback}
  end
end

defmodule Scheduler.JobRunner.Registry do
  @moduledoc false

  alias Scheduler.JobRunner.JobSpec

  @type t :: %{atom() => JobSpec.t()}

  @spec build([JobSpec.t()]) :: t()
  def build(specs) when is_list(specs) do
    Map.new(specs, fn %JobSpec{name: name} = spec -> {name, spec} end)
  end

  @spec fetch(t(), atom()) :: {:ok, JobSpec.t()} | :error
  def fetch(registry, name), do: Map.fetch(registry, name)

  @spec all_specs(t()) :: [JobSpec.t()]
  def all_specs(registry), do: Map.values(registry)
end
```
