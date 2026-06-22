**File:** `example_good_1173.md`

```elixir
defmodule JobQueue.Job do
  @moduledoc "Schema representing a durable background job record."

  use Ecto.Schema
  import Ecto.Changeset

  @type status :: :pending | :running | :completed | :failed | :retrying
  @type t :: %__MODULE__{
          id: Ecto.UUID.t() | nil,
          queue: String.t(),
          worker: String.t(),
          args: map(),
          status: status(),
          attempt: non_neg_integer(),
          max_attempts: pos_integer(),
          scheduled_at: DateTime.t(),
          locked_at: DateTime.t() | nil,
          completed_at: DateTime.t() | nil,
          error: String.t() | nil
        }

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "jobs" do
    field :queue, :string
    field :worker, :string
    field :args, :map
    field :status, Ecto.Enum, values: [:pending, :running, :completed, :failed, :retrying]
    field :attempt, :integer, default: 0
    field :max_attempts, :integer, default: 3
    field :scheduled_at, :utc_datetime_usec
    field :locked_at, :utc_datetime_usec
    field :completed_at, :utc_datetime_usec
    field :error, :string
    timestamps()
  end

  @spec enqueue_changeset(t(), map()) :: Ecto.Changeset.t()
  def enqueue_changeset(job, attrs) do
    job
    |> cast(attrs, [:queue, :worker, :args, :max_attempts, :scheduled_at])
    |> validate_required([:queue, :worker, :args])
    |> put_change(:status, :pending)
    |> put_change(:scheduled_at, Map.get(attrs, :scheduled_at, DateTime.utc_now()))
  end

  @spec lock_changeset(t(), DateTime.t()) :: Ecto.Changeset.t()
  def lock_changeset(job, locked_at) do
    job
    |> change(status: :running, locked_at: locked_at, attempt: job.attempt + 1)
  end

  @spec complete_changeset(t()) :: Ecto.Changeset.t()
  def complete_changeset(job) do
    change(job, status: :completed, completed_at: DateTime.utc_now())
  end

  @spec fail_changeset(t(), String.t()) :: Ecto.Changeset.t()
  def fail_changeset(job, error_message) do
    next_status = if job.attempt >= job.max_attempts, do: :failed, else: :retrying
    change(job, status: next_status, error: error_message)
  end
end

defmodule JobQueue.Worker do
  @moduledoc "Behaviour for implementing background job workers."

  @doc "Executes the job with the given arguments map."
  @callback perform(map()) :: :ok | {:error, term()}
end

defmodule JobQueue.Executor do
  @moduledoc """
  Fetches pending jobs from the queue, locks them, and executes their worker.
  Handles success, failure, and retry transitions atomically.
  """

  require Logger

  alias JobQueue.{Job, Worker}
  alias MyApp.Repo
  import Ecto.Query

  @spec run_next(String.t()) :: {:ok, :executed} | {:ok, :empty} | {:error, term()}
  def run_next(queue_name) when is_binary(queue_name) do
    case fetch_and_lock(queue_name) do
      {:ok, nil} ->
        {:ok, :empty}

      {:ok, job} ->
        execute_job(job)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp fetch_and_lock(queue_name) do
    now = DateTime.utc_now()

    Repo.transaction(fn ->
      job =
        Job
        |> where([j], j.queue == ^queue_name)
        |> where([j], j.status in [:pending, :retrying])
        |> where([j], j.scheduled_at <= ^now)
        |> order_by([j], asc: j.scheduled_at)
        |> limit(1)
        |> lock("FOR UPDATE SKIP LOCKED")
        |> Repo.one()

      case job do
        nil ->
          nil

        found ->
          found
          |> Job.lock_changeset(now)
          |> Repo.update!()
      end
    end)
  end

  defp execute_job(%Job{worker: worker_mod_string} = job) do
    worker_module = String.to_existing_atom("Elixir.#{worker_mod_string}")

    case worker_module.perform(job.args) do
      :ok ->
        job |> Job.complete_changeset() |> Repo.update()
        Logger.info("Job #{job.id} completed successfully")
        {:ok, :executed}

      {:error, reason} ->
        error_msg = inspect(reason)
        job |> Job.fail_changeset(error_msg) |> Repo.update()
        Logger.warning("Job #{job.id} failed: #{error_msg}")
        {:ok, :executed}
    end
  rescue
    exception ->
      error_msg = Exception.message(exception)
      job |> Job.fail_changeset(error_msg) |> Repo.update()
      Logger.error("Job #{job.id} raised an exception: #{error_msg}")
      {:ok, :executed}
  end
end
```
