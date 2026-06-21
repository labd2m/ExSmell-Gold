```elixir
defmodule Scheduler.Job do
  @moduledoc """
  Defines a scheduled job with its cron expression and target MFA.
  """

  @type t :: %__MODULE__{
          name: atom(),
          cron: String.t(),
          module: module(),
          function: atom(),
          args: [term()]
        }

  defstruct [:name, :cron, :module, :function, args: []]

  @spec new(atom(), String.t(), module(), atom(), [term()]) :: t()
  def new(name, cron, module, function, args \\ [])
      when is_atom(name) and is_binary(cron) and is_atom(module) and is_atom(function) do
    %__MODULE__{name: name, cron: cron, module: module, function: function, args: args}
  end
end

defmodule Scheduler do
  @moduledoc """
  A supervised, interval-driven job scheduler.

  Jobs are registered by name and fired when their cron expression matches
  the current wall-clock minute. Each execution runs inside a supervised
  Task so a crashing job does not take down the scheduler. The tick
  interval is configurable; defaults to 60 seconds aligned to wall-clock
  minute boundaries.
  """

  use GenServer

  require Logger

  alias Scheduler.Job

  @type opts :: [
          jobs: [Job.t()],
          tick_interval_ms: pos_integer()
        ]

  @spec start_link(opts()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec register(Job.t()) :: :ok
  def register(%Job{} = job) do
    GenServer.cast(__MODULE__, {:register, job})
  end

  @spec deregister(atom()) :: :ok
  def deregister(name) when is_atom(name) do
    GenServer.cast(__MODULE__, {:deregister, name})
  end

  @spec list_jobs() :: [Job.t()]
  def list_jobs do
    GenServer.call(__MODULE__, :list_jobs)
  end

  @impl GenServer
  def init(opts) do
    jobs =
      opts
      |> Keyword.get(:jobs, [])
      |> Map.new(fn %Job{name: name} = job -> {name, job} end)

    interval = Keyword.get(opts, :tick_interval_ms, 60_000)
    schedule_tick(interval)

    {:ok, %{jobs: jobs, interval: interval}}
  end

  @impl GenServer
  def handle_cast({:register, %Job{name: name} = job}, state) do
    {:noreply, %{state | jobs: Map.put(state.jobs, name, job)}}
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
    now = DateTime.utc_now()
    Enum.each(state.jobs, fn {_name, job} -> maybe_run(job, now) end)
    schedule_tick(state.interval)
    {:noreply, state}
  end

  defp maybe_run(%Job{} = job, %DateTime{} = now) do
    if Crontab.CronExpression.Composer.compose(job.cron) |> matches_now?(now) do
      Task.Supervisor.start_child(Scheduler.TaskSupervisor, fn ->
        Logger.info("Running scheduled job", job: job.name)
        apply(job.module, job.function, job.args)
      end)
    end
  end

  defp matches_now?(cron_expression, now) do
    Crontab.DateChecker.matches_date?(cron_expression, NaiveDateTime.from_erl!(DateTime.to_erl(now)))
  rescue
    _ -> false
  end

  defp schedule_tick(interval) do
    Process.send_after(self(), :tick, interval)
  end
end
```
