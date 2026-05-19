```elixir
defmodule JobScheduler do
  @moduledoc """
  Schedules background jobs for deferred execution.
  """

  def init do
    Agent.start_link(fn -> %{jobs: %{}, counters: %{total: 0, failed: 0}} end)
  end

  def schedule(pid, job_id, %{module: _mod, args: _args} = job_spec) do
    Agent.update(pid, fn state ->
      job = Map.merge(job_spec, %{
        id: job_id,
        status: :scheduled,
        scheduled_at: DateTime.utc_now(),
        attempts: 0
      })
      new_jobs = Map.put(state.jobs, job_id, job)
      new_counters = Map.update!(state.counters, :total, &(&1 + 1))
      %{state | jobs: new_jobs, counters: new_counters}
    end)
    {:ok, job_id}
  end

  def list_scheduled(pid) do
    Agent.get(pid, fn state ->
      state.jobs
      |> Map.values()
      |> Enum.filter(&(&1.status == :scheduled))
    end)
  end
end

defmodule JobRunner do
  @moduledoc """
  Executes scheduled jobs and updates their run state.
  """

  def mark_running(pid, job_id) do
    Agent.update(pid, fn state ->
      updated = state.jobs
        |> Map.update!(job_id, fn job ->
          %{job | status: :running, started_at: DateTime.utc_now()}
        end)
      %{state | jobs: updated}
    end)
    :ok
  end

  def mark_completed(pid, job_id, result) do
    Agent.update(pid, fn state ->
      updated = Map.update!(state.jobs, job_id, fn job ->
        %{job | status: :completed, result: result, completed_at: DateTime.utc_now()}
      end)
      %{state | jobs: updated}
    end)
    :ok
  end
end

defmodule RetryPolicy do
  @moduledoc """
  Applies retry rules to failed background jobs.
  """

  @max_attempts 3

  def record_failure(pid, job_id, reason) do
    Agent.update(pid, fn state ->
      updated_jobs =
        Map.update!(state.jobs, job_id, fn job ->
          new_attempts = job.attempts + 1
          new_status = if new_attempts >= @max_attempts, do: :dead, else: :scheduled
          %{job | attempts: new_attempts, status: new_status, last_error: inspect(reason)}
        end)

      failed_count =
        if Map.fetch!(updated_jobs, job_id).status == :dead,
          do: state.counters.failed + 1,
          else: state.counters.failed

      %{state | jobs: updated_jobs, counters: %{state.counters | failed: failed_count}}
    end)
    :ok
  end

  def retryable?(pid, job_id) do
    Agent.get(pid, fn state ->
      job = Map.get(state.jobs, job_id, %{attempts: @max_attempts})
      job.attempts < @max_attempts
    end)
  end
end

defmodule JobMonitor do
  @moduledoc """
  Monitors job queue health and produces status reports.
  """

  def status_report(pid) do
    state = Agent.get(pid, fn s -> s end)

    by_status = Enum.group_by(Map.values(state.jobs), & &1.status)

    %{
      total_jobs: state.counters.total,
      total_failed: state.counters.failed,
      scheduled: length(Map.get(by_status, :scheduled, [])),
      running: length(Map.get(by_status, :running, [])),
      completed: length(Map.get(by_status, :completed, [])),
      dead: length(Map.get(by_status, :dead, []))
    }
  end

  def dead_jobs(pid) do
    Agent.get(pid, fn state ->
      state.jobs
      |> Map.values()
      |> Enum.filter(&(&1.status == :dead))
    end)
  end
end
```
