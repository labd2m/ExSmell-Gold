```elixir
defmodule MyApp.Scheduler do
  @moduledoc """
  A lightweight cron-style task scheduler that runs registered jobs on
  configurable intervals using a single GenServer and `Process.send_after/3`.
  Each job runs in an isolated `Task` under a shared `Task.Supervisor`
  so that a crashing job does not affect the scheduler or other jobs.

  Jobs are registered at startup via configuration and cannot be added
  or removed at runtime without a restart. For dynamic scheduling, use
  an Oban queue instead.

  Start this module under the application supervisor:

      children = [
        {Task.Supervisor, name: MyApp.Scheduler.TaskSupervisor},
        MyApp.Scheduler
      ]
  """

  use GenServer

  require Logger

  @task_sup MyApp.Scheduler.TaskSupervisor

  @type job :: %{
          name: String.t(),
          module: module(),
          function: atom(),
          args: list(),
          interval_ms: pos_integer()
        }

  @type state :: %{jobs: [job()]}

  @doc "Starts the scheduler with the jobs provided in `opts[:jobs]`."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl GenServer
  def init(opts) do
    jobs = Keyword.get(opts, :jobs, default_jobs())
    Enum.each(jobs, &schedule_first_run/1)
    {:ok, %{jobs: jobs}}
  end

  @impl GenServer
  def handle_info({:run_job, job}, state) do
    execute_job(job)
    schedule_next_run(job)
    {:noreply, state}
  end

  @spec execute_job(job()) :: Task.t()
  defp execute_job(job) do
    Task.Supervisor.start_child(@task_sup, fn ->
      Logger.info("scheduler_job_started", job: job.name)
      start_ms = System.monotonic_time(:millisecond)

      try do
        apply(job.module, job.function, job.args)
        duration = System.monotonic_time(:millisecond) - start_ms
        Logger.info("scheduler_job_finished", job: job.name, duration_ms: duration)
      rescue
        err ->
          Logger.error("scheduler_job_failed",
            job: job.name,
            error: Exception.message(err)
          )
      end
    end)
  end

  @spec schedule_first_run(job()) :: reference()
  defp schedule_first_run(job) do
    jitter = :rand.uniform(min(job.interval_ms, 5_000))
    Process.send_after(self(), {:run_job, job}, jitter)
  end

  @spec schedule_next_run(job()) :: reference()
  defp schedule_next_run(job) do
    Process.send_after(self(), {:run_job, job}, job.interval_ms)
  end

  @spec default_jobs() :: [job()]
  defp default_jobs do
    [
      %{
        name: "expire_stale_sessions",
        module: MyApp.Accounts.SessionToken,
        function: :delete_expired,
        args: [],
        interval_ms: 60 * 60 * 1_000
      },
      %{
        name: "refresh_feature_flags",
        module: MyApp.FeatureFlags,
        function: :reload,
        args: [],
        interval_ms: 5 * 60 * 1_000
      },
      %{
        name: "evict_stale_device_commands",
        module: MyApp.Devices.CommandSweeper,
        function: :run,
        args: [],
        interval_ms: 15 * 60 * 1_000
      }
    ]
  end
end
```
