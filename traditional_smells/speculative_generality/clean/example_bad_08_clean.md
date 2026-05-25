```elixir
defmodule Scheduling.JobQueue do
  @moduledoc """
  Manages the lifecycle of background jobs: enqueuing, scheduling, cancellation,
  and status tracking. Built on top of a persistent job store that survives
  application restarts.
  """

  alias Scheduling.{Job, JobLog, Repo}

  @max_queue_depth  10_000
  @default_timeout  300

  def enqueue(job_type, payload, priority \\ :normal) do
    queue_depth = count_pending()

    if queue_depth >= @max_queue_depth do
      {:error, :queue_full}
    else
      attrs = %{
        type:         job_type,
        payload:      payload,
        priority:     priority,
        status:       :queued,
        attempts:     0,
        max_attempts: 3,
        timeout:      @default_timeout,
        queued_at:    DateTime.utc_now(),
        run_at:       DateTime.utc_now()
      }

      case Job.changeset(%Job{}, attrs) |> Repo.insert() do
        {:ok, job}  -> {:ok, job}
        {:error, cs} -> {:error, cs}
      end
    end
  end

  def enqueue_recurring(job_type, payload) do
    case enqueue(job_type, payload) do
      {:ok, job} ->
        job
        |> Job.changeset(%{recurring: true})
        |> Repo.update()

      {:error, reason} ->
        {:error, reason}
    end
  end

  def enqueue_bulk(job_type, payloads) when is_list(payloads) do
    Enum.reduce(payloads, {[], []}, fn payload, {ok_acc, err_acc} ->
      case enqueue(job_type, payload) do
        {:ok, job}  -> {[job | ok_acc], err_acc}
        {:error, e} -> {ok_acc, [e | err_acc]}
      end
    end)
  end

  def schedule_at(job_type, payload, run_at) do
    case enqueue(job_type, payload) do
      {:ok, job} ->
        job
        |> Job.changeset(%{run_at: run_at, status: :scheduled})
        |> Repo.update()

      {:error, reason} ->
        {:error, reason}
    end
  end

  def cancel(job_id) do
    job = Repo.get!(Job, job_id)

    if job.status in [:queued, :scheduled] do
      job
      |> Job.changeset(%{status: :cancelled, cancelled_at: DateTime.utc_now()})
      |> Repo.update()
    else
      {:error, :not_cancellable}
    end
  end

  def mark_running(job_id) do
    job = Repo.get!(Job, job_id)

    job
    |> Job.changeset(%{status: :running, started_at: DateTime.utc_now()})
    |> Repo.update()
  end

  def mark_completed(job_id, result_meta \\ %{}) do
    job = Repo.get!(Job, job_id)

    job
    |> Job.changeset(%{
      status:       :completed,
      result_meta:  result_meta,
      completed_at: DateTime.utc_now()
    })
    |> Repo.update()

    JobLog.record!(:completed, job_id)
  end

  def mark_failed(job_id, error_message) do
    job = Repo.get!(Job, job_id)
    new_attempts = job.attempts + 1

    status = if new_attempts >= job.max_attempts, do: :dead, else: :failed

    job
    |> Job.changeset(%{
      status:       status,
      attempts:     new_attempts,
      error:        error_message,
      failed_at:    DateTime.utc_now()
    })
    |> Repo.update()

    if status == :dead, do: JobLog.record!(:dead_letter, job_id)
  end

  def pending_jobs do
    Job
    |> Repo.all()
    |> Enum.filter(&(&1.status in [:queued, :scheduled]))
    |> Enum.sort_by(& &1.run_at, DateTime)
  end

  def stats do
    jobs = Repo.all(Job)

    %{
      queued:    Enum.count(jobs, &(&1.status == :queued)),
      running:   Enum.count(jobs, &(&1.status == :running)),
      completed: Enum.count(jobs, &(&1.status == :completed)),
      failed:    Enum.count(jobs, &(&1.status == :failed)),
      dead:      Enum.count(jobs, &(&1.status == :dead))
    }
  end


  defp count_pending do
    Job
    |> Repo.all()
    |> Enum.count(&(&1.status in [:queued, :scheduled]))
  end
end
```
