```elixir
defmodule JobScheduler do
  @moduledoc """
  Manages background job scheduling, queue routing, retry policies,
  and failure handling for the async processing layer.
  """

  require Logger

  @priorities [:critical, :high, :normal, :low]

  def valid_priorities, do: @priorities







  @doc """
  Returns the name of the processing queue to which the job should be routed,
  based on its priority level.
  """
  def queue_name(%{priority: priority}) do
    case priority do
      :critical -> "critical"
      :high -> "high_priority"
      :normal -> "default"
      :low -> "background"
      _ -> "default"
    end
  end

  @doc """
  Returns the maximum number of retry attempts for a failed job of this priority.
  """
  def max_retries(%{priority: priority}) do
    case priority do
      :critical -> 10
      :high -> 7
      :normal -> 5
      :low -> 3
      _ -> 5
    end
  end

  @doc """
  Returns the base backoff interval in seconds used when computing the delay
  before the next retry attempt.
  """
  def retry_backoff_seconds(%{priority: priority}) do
    case priority do
      :critical -> 5
      :high -> 15
      :normal -> 30
      :low -> 120
      _ -> 30
    end
  end



  @doc """
  Builds the full scheduling configuration for a job, combining queue, retry,
  and backoff settings.
  """
  def scheduling_config(%{} = job) do
    %{
      queue: queue_name(job),
      max_retries: max_retries(job),
      backoff_seconds: retry_backoff_seconds(job),
      unique_for: Map.get(job, :unique_for, 0)
    }
  end

  @doc """
  Computes the next scheduled run time for a job based on its attempt number
  and exponential backoff settings.
  """
  def next_run_at(%{} = job, attempt) when attempt > 0 do
    base = retry_backoff_seconds(job)
    jitter = :rand.uniform(5)
    delay_seconds = trunc(base * :math.pow(2, attempt - 1)) + jitter
    DateTime.add(DateTime.utc_now(), delay_seconds, :second)
  end

  @doc """
  Decides whether a job should be retried given its current attempt count.
  """
  def should_retry?(%{} = job, attempt) do
    attempt <= max_retries(job)
  end

  @doc """
  Enqueues a job struct for processing, setting scheduling defaults if absent.
  """
  def enqueue(%{id: _id, type: _type} = job) do
    job_with_defaults =
      job
      |> Map.put_new(:priority, :normal)
      |> Map.put_new(:attempt, 0)
      |> Map.put_new(:enqueued_at, DateTime.utc_now())

    config = scheduling_config(job_with_defaults)

    Logger.info(
      "Enqueued job #{job.id} (#{job.type}) on queue '#{config.queue}' " <>
        "with priority #{job_with_defaults.priority}."
    )

    {:ok, Map.merge(job_with_defaults, %{config: config, status: :enqueued})}
  end

  @doc """
  Handles a job failure by computing the next retry or marking it as dead.
  """
  def handle_failure(%{attempt: attempt} = job, reason) do
    next_attempt = attempt + 1

    if should_retry?(job, next_attempt) do
      run_at = next_run_at(job, next_attempt)
      Logger.warning("Job #{job.id} failed (attempt #{attempt}): #{inspect(reason)}. Retrying at #{run_at}.")
      {:retry, %{job | attempt: next_attempt, next_run_at: run_at, status: :retrying}}
    else
      Logger.error("Job #{job.id} exhausted retries after #{attempt} attempts: #{inspect(reason)}.")
      {:dead, %{job | status: :dead, dead_at: DateTime.utc_now()}}
    end
  end

  @doc """
  Returns a summary report of jobs grouped by priority and queue.
  """
  def queue_summary(jobs) when is_list(jobs) do
    Enum.group_by(jobs, &queue_name/1)
    |> Enum.map(fn {queue, queued_jobs} ->
      %{
        queue: queue,
        count: length(queued_jobs),
        priorities: Enum.map(queued_jobs, & &1.priority) |> Enum.uniq()
      }
    end)
  end
end
```
