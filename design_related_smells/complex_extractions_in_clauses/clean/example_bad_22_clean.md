```elixir
defmodule Scheduler.JobDispatcher do
  @moduledoc """
  Schedules and dispatches background jobs across queues based on
  job type and priority level.
  """

  alias Scheduler.{Job, Queue, JobRegistry, WorkerPool}
  alias Scheduler.{AuditTrail, RateLimiter}

  @critical_priority 9
  @high_priority 6

  # `owner_id` are extracted in every clause head despite being used only
  # inside the function body. Only `type` (structurally matched) and
  # `priority` (compared in guards) are needed in the clause head to perform
  # dispatch. Readers must parse through all six bindings in every clause
  # just to understand what the branching actually depends on.

  def schedule_job(%Job{
        type: :report_generation,
        priority: priority,
        run_at: run_at,
        job_id: job_id,
        payload: payload,
        owner_id: owner_id
      })
      when priority >= @critical_priority do
    :ok = RateLimiter.check!(:report_generation, owner_id, :critical)
    queue = Queue.critical(:report_generation)

    WorkerPool.enqueue(queue, %{
      job_id: job_id,
      payload: payload,
      run_at: run_at,
      owner_id: owner_id
    })

    AuditTrail.log(job_id, owner_id, :scheduled_critical)
    JobRegistry.register(job_id, :report_generation, :queued, run_at)
    {:ok, :critical, job_id}
  end

  def schedule_job(%Job{
        type: :report_generation,
        priority: priority,
        run_at: run_at,
        job_id: job_id,
        payload: payload,
        owner_id: owner_id
      })
      when priority >= @high_priority do
    :ok = RateLimiter.check!(:report_generation, owner_id, :high)
    queue = Queue.high(:report_generation)

    WorkerPool.enqueue(queue, %{
      job_id: job_id,
      payload: payload,
      run_at: run_at,
      owner_id: owner_id
    })

    AuditTrail.log(job_id, owner_id, :scheduled_high)
    JobRegistry.register(job_id, :report_generation, :queued, run_at)
    {:ok, :high, job_id}
  end

  def schedule_job(%Job{
        type: :data_export,
        priority: priority,
        run_at: run_at,
        job_id: job_id,
        payload: payload,
        owner_id: owner_id
      })
      when priority >= @high_priority do
    :ok = RateLimiter.check!(:data_export, owner_id, :high)
    queue = Queue.high(:data_export)

    WorkerPool.enqueue(queue, %{
      job_id: job_id,
      payload: payload,
      run_at: run_at,
      owner_id: owner_id
    })

    AuditTrail.log(job_id, owner_id, :scheduled_high)
    JobRegistry.register(job_id, :data_export, :queued, run_at)
    {:ok, :high, job_id}
  end

  def schedule_job(%Job{
        type: type,
        priority: priority,
        run_at: run_at,
        job_id: job_id,
        payload: payload,
        owner_id: owner_id
      })
      when priority < @high_priority do
    :ok = RateLimiter.check!(type, owner_id, :normal)
    queue = Queue.normal(type)

    WorkerPool.enqueue(queue, %{
      job_id: job_id,
      payload: payload,
      run_at: run_at,
      owner_id: owner_id
    })

    AuditTrail.log(job_id, owner_id, :scheduled_normal)
    JobRegistry.register(job_id, type, :queued, run_at)
    {:ok, :normal, job_id}
  end


  def schedule_job(%Job{job_id: job_id}) do
    Logger.error("Unhandled job configuration for #{job_id}")
    {:error, :unschedulable}
  end
end
```
