```elixir
defmodule JobSchedulerTask do
  @moduledoc """
  Schedules and executes background jobs for a given tenant.
  Each tenant gets one scheduler Task that manages a queue of
  recurring and one-shot jobs.
  """

  require Logger

  @tick_interval_ms 1_000

  @type job :: %{
          id: String.t(),
          name: String.t(),
          run_at: DateTime.t(),
          recur_seconds: non_neg_integer() | nil,
          handler: (-> :ok | {:error, term()}),
          last_run: DateTime.t() | nil,
          run_count: non_neg_integer()
        }

  @doc "Starts a scheduler Task for a tenant with an initial set of jobs."
  def start_scheduler(initial_jobs \\ []) do
    Task.start(fn ->
      Logger.info("[JobSchedulerTask] Scheduler starting with #{length(initial_jobs)} jobs")

      scheduler_loop(initial_jobs, %{started_at: DateTime.utc_now(), ticks: 0})
    end)
  end

  defp scheduler_loop(jobs, meta) do
    receive do
      {:add_job, job, from_pid} ->
        Logger.info("[JobSchedulerTask] Adding job #{job.id}: #{job.name}")
        send(from_pid, {:add_result, :ok})
        scheduler_loop([job | jobs], meta)

      {:cancel_job, job_id, from_pid} ->
        remaining = Enum.reject(jobs, &(&1.id == job_id))
        cancelled = length(jobs) - length(remaining)

        if cancelled > 0 do
          Logger.info("[JobSchedulerTask] Cancelled job #{job_id}")
          send(from_pid, {:cancel_result, :ok})
        else
          send(from_pid, {:cancel_result, {:error, :not_found}})
        end

        scheduler_loop(remaining, meta)

      {:list_jobs, from_pid} ->
        summary =
          Enum.map(jobs, fn j ->
            Map.take(j, [:id, :name, :run_at, :last_run, :run_count])
          end)

        send(from_pid, {:jobs_list, summary})
        scheduler_loop(jobs, meta)

      {:status, from_pid} ->
        send(from_pid, {:status_reply, %{
          job_count: length(jobs),
          started_at: meta.started_at,
          ticks: meta.ticks
        }})
        scheduler_loop(jobs, meta)

      :stop ->
        Logger.info("[JobSchedulerTask] Scheduler stopping gracefully")
        :ok
    after
      @tick_interval_ms ->
        now = DateTime.utc_now()

        {due, pending} = Enum.split_with(jobs, fn j ->
          not j[:cancelled] and DateTime.compare(j.run_at, now) != :gt
        end)

        rescheduled =
          Enum.flat_map(due, fn job ->
            result = run_job(job)

            if job.recur_seconds do
              next_run = DateTime.add(now, job.recur_seconds, :second)
              updated = %{job | run_at: next_run, last_run: now, run_count: job.run_count + 1}
              [updated]
            else
              Logger.info("[JobSchedulerTask] One-shot job #{job.id} completed: #{inspect(result)}")
              []
            end
          end)

        updated_jobs = pending ++ rescheduled
        scheduler_loop(updated_jobs, %{meta | ticks: meta.ticks + 1})
    end
  end

  defp run_job(job) do
    Logger.info("[JobSchedulerTask] Running job #{job.id}: #{job.name}")

    try do
      job.handler.()
    rescue
      e ->
        Logger.error("[JobSchedulerTask] Job #{job.id} raised: #{inspect(e)}")
        {:error, :exception}
    end
  end

  @doc "Adds a job to the running scheduler Task."
  def add_job(scheduler_pid, job) do
    send(scheduler_pid, {:add_job, job, self()})

    receive do
      {:add_result, result} -> result
    after
      5_000 -> {:error, :timeout}
    end
  end

  @doc "Cancels a job by ID."
  def cancel_job(scheduler_pid, job_id) do
    send(scheduler_pid, {:cancel_job, job_id, self()})

    receive do
      {:cancel_result, result} -> result
    after
      5_000 -> {:error, :timeout}
    end
  end

  @doc "Lists jobs currently registered in the scheduler."
  def list_jobs(scheduler_pid) do
    send(scheduler_pid, {:list_jobs, self()})

    receive do
      {:jobs_list, jobs} -> {:ok, jobs}
    after
      5_000 -> {:error, :timeout}
    end
  end

  @doc "Requests a status summary from the scheduler Task."
  def get_status(scheduler_pid) do
    send(scheduler_pid, {:status, self()})

    receive do
      {:status_reply, status} -> {:ok, status}
    after
      5_000 -> {:error, :timeout}
    end
  end

  @doc "Stops the scheduler Task."
  def stop_scheduler(scheduler_pid) do
    send(scheduler_pid, :stop)
    :ok
  end
end
```
