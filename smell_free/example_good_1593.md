```elixir
defmodule IdempotentJob.Record do
  use Ecto.Schema
  import Ecto.Changeset

  @moduledoc """
  Tracks the execution state of an idempotent background job keyed
  by a caller-supplied idempotency key. Prevents duplicate side effects
  when jobs are retried after transient failures.
  """

  @type status :: :pending | :processing | :completed | :failed

  @type t :: %__MODULE__{
          id: Ecto.UUID.t(),
          idempotency_key: String.t(),
          job_type: String.t(),
          status: status(),
          result: map() | nil,
          error: String.t() | nil,
          completed_at: DateTime.t() | nil
        }

  @primary_key {:id, :binary_id, autogenerate: true}

  schema "idempotent_jobs" do
    field :idempotency_key, :string
    field :job_type, :string
    field :status, Ecto.Enum, values: [:pending, :processing, :completed, :failed]
    field :result, :map
    field :error, :string
    field :completed_at, :utc_datetime
    timestamps()
  end

  @spec create_changeset(map()) :: Ecto.Changeset.t()
  def create_changeset(attrs) do
    %__MODULE__{}
    |> cast(attrs, [:idempotency_key, :job_type])
    |> validate_required([:idempotency_key, :job_type])
    |> put_change(:status, :pending)
    |> unique_constraint(:idempotency_key)
  end

  @spec complete_changeset(t(), map()) :: Ecto.Changeset.t()
  def complete_changeset(record, result) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    change(record, status: :completed, result: result, completed_at: now)
  end

  @spec fail_changeset(t(), String.t()) :: Ecto.Changeset.t()
  def fail_changeset(record, reason) do
    change(record, status: :failed, error: reason)
  end
end

defmodule IdempotentJob.Processor do
  alias IdempotentJob.Record
  alias MyApp.Repo

  @moduledoc """
  Executes a job function exactly once per idempotency key.
  Returns the cached result for keys that have already succeeded.
  """

  @type job_fn :: (-> {:ok, map()} | {:error, String.t()})

  @spec run(String.t(), String.t(), job_fn()) ::
          {:ok, map()} | {:error, :already_failed | :conflict | term()}
  def run(idempotency_key, job_type, function)
      when is_binary(idempotency_key) and is_binary(job_type) and is_function(function, 0) do
    case find_or_create(idempotency_key, job_type) do
      {:existing, %Record{status: :completed, result: result}} ->
        {:ok, result}

      {:existing, %Record{status: :failed}} ->
        {:error, :already_failed}

      {:existing, %Record{status: :processing}} ->
        {:error, :conflict}

      {:new, record} ->
        execute_and_record(record, function)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp find_or_create(key, job_type) do
    case Repo.get_by(Record, idempotency_key: key) do
      %Record{} = existing ->
        {:existing, existing}

      nil ->
        case %Record{}
             |> Record.create_changeset(%{idempotency_key: key, job_type: job_type})
             |> Repo.insert() do
          {:ok, record} -> {:new, record}
          {:error, changeset} -> {:error, changeset}
        end
    end
  end

  defp execute_and_record(record, function) do
    Repo.update!(Ecto.Changeset.change(record, status: :processing))

    case function.() do
      {:ok, result} ->
        record
        |> Record.complete_changeset(result)
        |> Repo.update!()

        {:ok, result}

      {:error, reason} ->
        record
        |> Record.fail_changeset(reason)
        |> Repo.update!()

        {:error, reason}
    end
  end
end
```
