```elixir
defmodule Workers.JobQueue do
  @moduledoc """
  A lightweight, durable job queue backed by PostgreSQL using `SELECT FOR
  UPDATE SKIP LOCKED`. Multiple worker processes can safely poll the queue
  in parallel without double-processing a job. This implementation is
  intentionally simple — it covers use cases where adding Oban is not
  justified, but a transient in-memory queue is too fragile.
  Jobs transition through `:pending → :running → :done | :failed`.
  """

  alias Workers.{Job, Repo}
  import Ecto.Query

  require Logger

  @type queue_name :: binary()
  @type job_attrs :: %{
          required(:queue) => queue_name(),
          required(:payload) => map(),
          optional(:run_at) => DateTime.t(),
          optional(:max_attempts) => pos_integer()
        }

  @default_max_attempts 3
  @default_claim_limit 10

  @doc """
  Inserts a new job into the queue. `run_at` defaults to `now()` for
  immediate availability. Returns `{:ok, job}` or `{:error, changeset}`.
  """
  @spec enqueue(job_attrs()) :: {:ok, Job.t()} | {:error, Ecto.Changeset.t()}
  def enqueue(%{queue: queue, payload: payload} = attrs)
      when is_binary(queue) and is_map(payload) do
    %Job{}
    |> Job.changeset(%{
      queue: queue,
      payload: payload,
      run_at: Map.get(attrs, :run_at, DateTime.utc_now()),
      max_attempts: Map.get(attrs, :max_attempts, @default_max_attempts),
      status: :pending,
      attempt: 0
    })
    |> Repo.insert()
  end

  @doc """
  Claims up to `limit` pending jobs from `queue` that are due for processing.
  Uses `SELECT FOR UPDATE SKIP LOCKED` so concurrent pollers never claim the
  same job. Returns a list of claimed `Job` structs.
  """
  @spec claim(queue_name(), pos_integer()) :: [Job.t()]
  def claim(queue, limit \\ @default_claim_limit)
      when is_binary(queue) and is_integer(limit) and limit > 0 do
    now = DateTime.utc_now()

    Repo.transaction(fn ->
      ids =
        Job
        |> where([j], j.queue == ^queue)
        |> where([j], j.status == :pending)
        |> where([j], j.run_at <= ^now)
        |> where([j], j.attempt < j.max_attempts)
        |> order_by([j], asc: j.run_at)
        |> limit(^limit)
        |> select([j], j.id)
        |> lock("FOR UPDATE SKIP LOCKED")
        |> Repo.all()

      {_count, jobs} =
        Job
        |> where([j], j.id in ^ids)
        |> update([j],
          set: [status: :running, attempt: j.attempt + 1, claimed_at: ^now]
        )
        |> select([j], j)
        |> Repo.update_all([])

      jobs
    end)
    |> case do
      {:ok, jobs} -> jobs
      {:error, _reason} -> []
    end
  end

  @doc """
  Marks a job as successfully completed and records the result.
  """
  @spec ack(Job.t(), map()) :: {:ok, Job.t()} | {:error, term()}
  def ack(%Job{} = job, result \\ %{}) do
    job
    |> Job.changeset(%{status: :done, result: result, completed_at: DateTime.utc_now()})
    |> Repo.update()
  end

  @doc """
  Records a job failure. If the job has remaining attempts it is re-queued
  with an exponential backoff delay; otherwise it transitions to `:failed`.
  """
  @spec nack(Job.t(), term()) :: {:ok, Job.t()} | {:error, term()}
  def nack(%Job{} = job, reason) do
    if job.attempt < job.max_attempts do
      delay_seconds = backoff_seconds(job.attempt)
      run_at = DateTime.add(DateTime.utc_now(), delay_seconds, :second)

      Logger.info("Re-queuing failed job",
        job_id: job.id,
        attempt: job.attempt,
        next_run_in_seconds: delay_seconds
      )

      job
      |> Job.changeset(%{status: :pending, run_at: run_at, last_error: inspect(reason)})
      |> Repo.update()
    else
      Logger.warning("Job exhausted all attempts",
        job_id: job.id,
        queue: job.queue,
        reason: inspect(reason)
      )

      job
      |> Job.changeset(%{status: :failed, last_error: inspect(reason), failed_at: DateTime.utc_now()})
      |> Repo.update()
    end
  end

  @doc """
  Returns queue depth counts grouped by status for monitoring.
  """
  @spec stats(queue_name()) :: %{atom() => non_neg_integer()}
  def stats(queue) when is_binary(queue) do
    Job
    |> where([j], j.queue == ^queue)
    |> group_by([j], j.status)
    |> select([j], {j.status, count(j.id)})
    |> Repo.all()
    |> Map.new()
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp backoff_seconds(attempt) do
    base = :math.pow(2, attempt) |> trunc()
    jitter = :rand.uniform(base)
    min(base + jitter, 3_600)
  end
end
```
