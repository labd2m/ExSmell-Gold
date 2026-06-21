```elixir
defmodule Idempotency.Record do
  @moduledoc false

  use Ecto.Schema
  import Ecto.Changeset

  @type status :: :processing | :completed | :failed

  @type t :: %__MODULE__{
          id: Ecto.UUID.t() | nil,
          key: String.t(),
          operation: String.t(),
          status: status(),
          response_status: non_neg_integer() | nil,
          response_body: String.t() | nil,
          inserted_at: DateTime.t() | nil
        }

  @primary_key {:id, :binary_id, autogenerate: true}

  schema "idempotency_records" do
    field :key, :string
    field :operation, :string
    field :status, Ecto.Enum, values: [:processing, :completed, :failed], default: :processing
    field :response_status, :integer
    field :response_body, :string
    timestamps(type: :utc_datetime)
  end

  @spec creation_changeset(t(), map()) :: Ecto.Changeset.t()
  def creation_changeset(record, params) do
    record
    |> cast(params, [:key, :operation])
    |> validate_required([:key, :operation])
    |> unique_constraint(:key, name: :idempotency_records_key_operation_index)
  end

  @spec completion_changeset(t(), non_neg_integer(), String.t()) :: Ecto.Changeset.t()
  def completion_changeset(record, status_code, body) do
    change(record, status: :completed, response_status: status_code, response_body: body)
  end

  @spec failure_changeset(t()) :: Ecto.Changeset.t()
  def failure_changeset(record) do
    change(record, status: :failed)
  end
end

defmodule Idempotency.Store do
  @moduledoc """
  Deduplicates API operations using client-supplied idempotency keys.

  When a request arrives with a key already in the store, the stored
  response is returned immediately without re-executing the operation.
  Keys in `:processing` status indicate a concurrent in-flight request;
  callers receive `{:error, :request_in_flight}` and should retry.
  """

  alias Idempotency.{Record, Repo}
  import Ecto.Query, warn: false

  @type handle_result :: {:ok, {non_neg_integer(), String.t()}} | {:error, term()}

  @spec check_or_create(String.t(), String.t()) ::
          {:ok, :proceed}
          | {:ok, :cached, non_neg_integer(), String.t()}
          | {:error, :request_in_flight}
          | {:error, term()}
  def check_or_create(key, operation) when is_binary(key) and is_binary(operation) do
    case Repo.get_by(Record, key: key) do
      nil -> create_record(key, operation)
      %Record{status: :completed, response_status: s, response_body: b} -> {:ok, :cached, s, b}
      %Record{status: :processing} -> {:error, :request_in_flight}
      %Record{status: :failed} -> create_record(key, operation)
    end
  end

  @spec mark_complete(String.t(), non_neg_integer(), String.t()) :: :ok | {:error, term()}
  def mark_complete(key, status_code, body)
      when is_binary(key) and is_integer(status_code) and is_binary(body) do
    case Repo.get_by(Record, key: key) do
      nil ->
        {:error, :not_found}

      record ->
        record
        |> Record.completion_changeset(status_code, body)
        |> Repo.update()
        |> case do
          {:ok, _} -> :ok
          {:error, _} = err -> err
        end
    end
  end

  @spec mark_failed(String.t()) :: :ok | {:error, term()}
  def mark_failed(key) when is_binary(key) do
    case Repo.get_by(Record, key: key) do
      nil ->
        {:error, :not_found}

      record ->
        record
        |> Record.failure_changeset()
        |> Repo.update()
        |> case do
          {:ok, _} -> :ok
          {:error, _} = err -> err
        end
    end
  end

  defp create_record(key, operation) do
    case %Record{} |> Record.creation_changeset(%{key: key, operation: operation}) |> Repo.insert() do
      {:ok, _record} -> {:ok, :proceed}
      {:error, %Ecto.Changeset{errors: [key: {_, [constraint: :unique | _]}]}} ->
        {:error, :request_in_flight}
      {:error, changeset} -> {:error, changeset}
    end
  end
end
```
