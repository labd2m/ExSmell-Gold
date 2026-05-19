# Annotated Example 06 — Agent Obsession

## Metadata

- **Smell name:** Agent Obsession
- **Expected smell location:** Modules `JobScheduler`, `JobRunner`, `RetryPolicy`, and `JobMonitor` all interact directly with the Agent PID
- **Affected functions:** `JobScheduler.schedule/3`, `JobRunner.mark_running/2`, `RetryPolicy.record_failure/3`, `JobMonitor.status_report/1`
- **Short explanation:** A background job registry is stored in an Agent, but scheduling, execution tracking, retry logic, and monitoring modules all interact with the Agent directly. The responsibilities are not encapsulated, and the state format is determined collectively by all callers.

---

```elixir
defmodule JobScheduler do
  @moduledoc """
  Schedules background jobs for deferred execution.
  """

  def init do
    Agent.start_link(fn -> %{jobs: %{}, counters: %{total: 0, failed: 0}} end)
  end

  # VALIDATION: SMELL START - Agent Obsession
  # VALIDATION: This is a smell because JobScheduler directly calls
  # Agent.update/2 to register a new job. No dedicated module owns the Agent
  # — any caller can alter the jobs map structure freely.
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
  # VALIDATION: SMELL END

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

  # VALIDATION: SMELL START - Agent Obsession
  # VALIDATION: This is a smell because JobRunner directly updates the job
  # entry inside the Agent using Agent.update/2, changing the :status field.
  # This bypasses any encapsulation and tightly couples JobRunner to the
  # exact map structure chosen by JobScheduler.
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
  # VALIDATION: SMELL END

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

  # VALIDATION: SMELL START - Agent Obsession
  # VALIDATION: This is a smell because RetryPolicy also calls Agent.update/2
  # directly, modifying the :attempts and :status fields of a job entry and
  # also incrementing the :failed counter — neither of which it owns. This
  # spreads the Agent mutation responsibility across yet another module.
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
  # VALIDATION: SMELL END

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
    # VALIDATION: SMELL START - Agent Obsession
    # VALIDATION: This is a smell because JobMonitor reads the full Agent state
    # with Agent.get/2 and directly accesses the :jobs and :counters keys that
    # were defined by the other modules. It is tightly coupled to their
    # internal Agent structure with no encapsulating interface.
    state = Agent.get(pid, fn s -> s end)
    # VALIDATION: SMELL END

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
