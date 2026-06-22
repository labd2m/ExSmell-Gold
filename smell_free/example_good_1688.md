```elixir
defmodule Jobqueue.Worker do
  @moduledoc """
  Supervised GenServer that polls a database-backed job queue and dispatches
  jobs to registered handler modules.

  Each handler module implements the `Jobqueue.Handler` behaviour. The worker
  claims jobs atomically using a database lock to prevent double-execution in
  multi-node deployments.
  """

  use GenServer

  require Logger

  alias Jobqueue.{Queue, HandlerRegistry, JobRecord}

  @poll_interval_ms 5_000
  @claim_batch_size 5

  @doc false
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl GenServer
  def init(opts) do
    registry = Keyword.get(opts, :handler_registry, HandlerRegistry.default())
    schedule_poll()
    {:ok, %{registry: registry}}
  end

  @impl GenServer
  def handle_info(:poll, %{registry: registry} = state) do
    claimed = Queue.claim_batch(@claim_batch_size)
    Enum.each(claimed, &dispatch_job(&1, registry))
    schedule_poll()
    {:noreply, state}
  end

  defp dispatch_job(%JobRecord{} = job, registry) do
    case HandlerRegistry.fetch(registry, job.job_type) do
      {:ok, handler} ->
        execute_job(job, handler)

      :error ->
        Logger.warning("no handler registered for job type: #{job.job_type}")
        Queue.mark_failed(job, "no handler registered")
    end
  end

  defp execute_job(job, handler) do
    handler.perform(job.payload)
    Queue.mark_complete(job)
    Logger.debug("completed job #{job.id} of type #{job.job_type}")
  rescue
    err ->
      reason = Exception.message(err)
      Logger.error("job #{job.id} failed: #{reason}")
      Queue.mark_failed(job, reason)
  end

  defp schedule_poll, do: Process.send_after(self(), :poll, @poll_interval_ms)
end

defmodule Jobqueue.Handler do
  @moduledoc "Behaviour contract for job handler modules."

  @callback perform(map()) :: :ok | {:error, String.t()}
end

defmodule Jobqueue.Queue do
  @moduledoc """
  Database operations for the job queue: claiming, completing, and failing jobs.
  """

  import Ecto.Query

  alias Jobqueue.Repo
  alias Jobqueue.JobRecord

  @spec claim_batch(pos_integer()) :: [JobRecord.t()]
  def claim_batch(limit) when is_integer(limit) and limit > 0 do
    now = DateTime.utc_now()

    Repo.transaction(fn ->
      ids =
        JobRecord
        |> where([j], j.status == :pending and j.scheduled_at <= ^now)
        |> order_by([j], asc: j.scheduled_at)
        |> limit(^limit)
        |> lock("FOR UPDATE SKIP LOCKED")
        |> select([j], j.id)
        |> Repo.all()

      {_count, jobs} =
        JobRecord
        |> where([j], j.id in ^ids)
        |> Repo.update_all([set: [status: :running, claimed_at: now]], returning: true)

      jobs
    end)
    |> case do
      {:ok, jobs} -> jobs
      {:error, _} -> []
    end
  end

  @spec mark_complete(JobRecord.t()) :: :ok
  def mark_complete(%JobRecord{} = job) do
    job
    |> JobRecord.complete_changeset(%{status: :complete, completed_at: DateTime.utc_now()})
    |> Repo.update()

    :ok
  end

  @spec mark_failed(JobRecord.t(), String.t()) :: :ok
  def mark_failed(%JobRecord{} = job, reason) when is_binary(reason) do
    job
    |> JobRecord.fail_changeset(%{
      status: :failed,
      error_reason: reason,
      failed_at: DateTime.utc_now(),
      attempt_count: job.attempt_count + 1
    })
    |> Repo.update()

    :ok
  end
end

defmodule Jobqueue.HandlerRegistry do
  @moduledoc "Maps job type strings to handler modules."

  @type t :: %{String.t() => module()}

  @spec default() :: t()
  def default, do: %{}

  @spec register(t(), String.t(), module()) :: t()
  def register(registry, job_type, handler_module)
      when is_binary(job_type) and is_atom(handler_module) do
    Map.put(registry, job_type, handler_module)
  end

  @spec fetch(t(), String.t()) :: {:ok, module()} | :error
  def fetch(registry, job_type), do: Map.fetch(registry, job_type)
end
```
