```elixir
# ── file: lib/scheduling/job_runner.ex ──────────────────────────────────────


defmodule Scheduling.JobRunner do
  @moduledoc """
  Manages enqueueing, execution, and monitoring of background jobs.
  Defined in `lib/scheduling/job_runner.ex`.
  """

  alias Scheduling.{JobQueue, WorkerRegistry, JobStore}

  @max_concurrency 10
  @default_timeout_ms 30_000

  @type job_id :: String.t()

  @type job :: %{
    id: job_id(),
    module: module(),
    args: list(),
    priority: :high | :normal | :low,
    scheduled_at: DateTime.t() | nil,
    timeout_ms: pos_integer(),
    attempts: non_neg_integer(),
    max_attempts: pos_integer(),
    status: :queued | :running | :completed | :failed | :cancelled
  }

  @doc """
  Enqueue a new job for the given worker module with the provided arguments.
  Returns `{:ok, job_id}` or `{:error, reason}`.
  """
  @spec enqueue(module(), list(), keyword()) :: {:ok, job_id()} | {:error, String.t()}
  def enqueue(module, args, opts \\ []) do
    with :ok <- validate_worker(module) do
      job = %{
        id: generate_id(),
        module: module,
        args: args,
        priority: Keyword.get(opts, :priority, :normal),
        scheduled_at: Keyword.get(opts, :scheduled_at),
        timeout_ms: Keyword.get(opts, :timeout_ms, @default_timeout_ms),
        attempts: 0,
        max_attempts: Keyword.get(opts, :max_attempts, 3),
        status: :queued
      }

      with {:ok, _} <- JobStore.save(job),
           :ok <- JobQueue.push(job) do
        {:ok, job.id}
      else
        {:error, reason} -> {:error, "Failed to enqueue job: #{inspect(reason)}"}
      end
    end
  end

  @doc "Immediately execute a queued job within a supervised task."
  @spec run(job_id()) :: :ok | {:error, String.t()}
  def run(job_id) do
    with {:ok, job} <- JobStore.fetch(job_id),
         :ok <- check_concurrency() do
      JobStore.update(job_id, %{status: :running, attempts: job.attempts + 1})

      task =
        Task.async(fn ->
          apply(job.module, :perform, job.args)
        end)

      case Task.yield(task, job.timeout_ms) || Task.shutdown(task) do
        {:ok, _result} ->
          JobStore.update(job_id, %{status: :completed})

        nil ->
          JobStore.update(job_id, %{status: :failed, error: "timeout"})
          {:error, "Job #{job_id} timed out"}

        {:exit, reason} ->
          JobStore.update(job_id, %{status: :failed, error: inspect(reason)})
          {:error, "Job #{job_id} crashed: #{inspect(reason)}"}
      end
    end
  end

  @doc "Cancel a queued job so it will never execute."
  @spec cancel(job_id()) :: :ok | {:error, String.t()}
  def cancel(job_id) do
    case JobStore.fetch(job_id) do
      {:ok, %{status: :queued} = job} ->
        JobStore.update(job.id, %{status: :cancelled})
        JobQueue.remove(job_id)

      {:ok, %{status: s}} ->
        {:error, "Cannot cancel job in status: #{s}"}

      :not_found ->
        {:error, "Job not found: #{job_id}"}
    end
  end

  @doc "Return the current status of a job."
  @spec status(job_id()) :: {:ok, atom()} | {:error, String.t()}
  def status(job_id) do
    case JobStore.fetch(job_id) do
      {:ok, %{status: s}} -> {:ok, s}
      :not_found -> {:error, "Job not found: #{job_id}"}
    end
  end

  @doc "Return all queued jobs ordered by priority then enqueue time."
  @spec list_pending() :: [job()]
  def list_pending do
    JobStore.all(status: :queued)
    |> Enum.sort_by(&{priority_rank(&1.priority), &1.scheduled_at})
  end

  defp priority_rank(:high), do: 0
  defp priority_rank(:normal), do: 1
  defp priority_rank(:low), do: 2

  defp validate_worker(module) do
    if function_exported?(module, :perform, 1) or Code.ensure_loaded?(module) do
      :ok
    else
      {:error, "Module #{inspect(module)} is not a valid worker"}
    end
  end

  defp check_concurrency do
    running = JobStore.count(status: :running)
    if running < @max_concurrency, do: :ok, else: {:error, "Max concurrency reached"}
  end

  defp generate_id do
    :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
  end
end


# ── file: lib/scheduling/job_runner_metrics.ex ─────────────────────────────────────────────────────


defmodule Scheduling.JobRunner do
  @moduledoc """
  Telemetry and observability instrumentation for background job execution.
  """

  @doc "Attach Telemetry handlers for job lifecycle events."
  @spec attach_handlers() :: :ok
  def attach_handlers do
    events = [
      [:scheduling, :job, :enqueue],
      [:scheduling, :job, :start],
      [:scheduling, :job, :stop],
      [:scheduling, :job, :exception]
    ]

    :telemetry.attach_many("job-runner-metrics", events, &handle_event/4, %{})
  end

  @doc false
  def handle_event([:scheduling, :job, :enqueue], %{count: _}, meta, _cfg) do
    :telemetry.execute([:scheduler, :queue_depth], %{value: queue_depth()}, meta)
  end

  def handle_event([:scheduling, :job, :start], measurements, meta, _cfg) do
    :telemetry.execute(
      [:scheduler, :job_started],
      %{system_time: measurements.system_time},
      Map.take(meta, [:job_id, :module, :priority])
    )
  end

  def handle_event([:scheduling, :job, :stop], %{duration: dur}, meta, _cfg) do
    :telemetry.execute(
      [:scheduler, :job_completed],
      %{duration_ms: System.convert_time_unit(dur, :native, :millisecond)},
      Map.take(meta, [:job_id, :status])
    )
  end

  def handle_event([:scheduling, :job, :exception], %{duration: dur}, meta, _cfg) do
    :telemetry.execute(
      [:scheduler, :job_failed],
      %{duration_ms: System.convert_time_unit(dur, :native, :millisecond)},
      Map.take(meta, [:job_id, :kind, :reason])
    )
  end

  defp queue_depth do
    case :ets.info(:job_queue, :size) do
      :undefined -> 0
      size -> size
    end
  end
end

```
