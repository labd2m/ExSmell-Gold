```elixir
defmodule Sync.Checkpoint do
  use Ecto.Schema
  import Ecto.Changeset

  @moduledoc """
  Persists the last successfully processed position for each named sync job.
  Allows incremental sync jobs to resume after restart without full re-processing.
  """

  @type t :: %__MODULE__{
          job_name: String.t(),
          cursor: String.t() | nil,
          last_synced_at: DateTime.t() | nil,
          records_synced: non_neg_integer()
        }

  @primary_key {:job_name, :string, []}

  schema "sync_checkpoints" do
    field :cursor, :string
    field :last_synced_at, :utc_datetime
    field :records_synced, :integer, default: 0
    timestamps()
  end

  @spec changeset(t() | Ecto.Changeset.t(), map()) :: Ecto.Changeset.t()
  def changeset(checkpoint, attrs) do
    checkpoint
    |> cast(attrs, [:cursor, :last_synced_at, :records_synced])
  end
end

defmodule Sync.IncrementalJob do
  alias Sync.Checkpoint
  alias MyApp.Repo

  @moduledoc """
  Provides the scaffolding for reliable incremental synchronization jobs.
  Submodules implement `fetch_batch/2` and `process_record/1`; this module
  handles checkpointing, error recovery, and run summaries.
  """

  @callback fetch_batch(cursor :: String.t() | nil, limit :: pos_integer()) ::
              {:ok, [map()], String.t() | nil} | {:error, term()}

  @callback process_record(record :: map()) :: :ok | {:error, term()}

  @callback job_name() :: String.t()

  defmacro __using__(_opts) do
    quote do
      @behaviour Sync.IncrementalJob

      def run(opts \\ []) do
        Sync.IncrementalJob.run_job(__MODULE__, opts)
      end
    end
  end

  @spec run_job(module(), keyword()) :: {:ok, map()} | {:error, term()}
  def run_job(module, opts) do
    limit = Keyword.get(opts, :batch_size, 100)
    job_name = module.job_name()
    checkpoint = load_checkpoint(job_name)
    starting_cursor = if checkpoint, do: checkpoint.cursor, else: nil

    case process_incrementally(module, starting_cursor, limit, 0) do
      {:ok, {final_cursor, total}} ->
        save_checkpoint(job_name, final_cursor, total)
        {:ok, %{records_synced: total, final_cursor: final_cursor, job: job_name}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp process_incrementally(module, cursor, limit, total) do
    case module.fetch_batch(cursor, limit) do
      {:ok, [], _next_cursor} ->
        {:ok, {cursor, total}}

      {:ok, records, next_cursor} ->
        case apply_records(module, records) do
          {:ok, count} ->
            if is_nil(next_cursor) do
              {:ok, {next_cursor, total + count}}
            else
              process_incrementally(module, next_cursor, limit, total + count)
            end

          {:error, reason} ->
            {:error, reason}
        end

      {:error, reason} ->
        {:error, {:fetch_failed, reason}}
    end
  end

  defp apply_records(module, records) do
    result =
      Enum.reduce_while(records, 0, fn record, count ->
        case module.process_record(record) do
          :ok -> {:cont, count + 1}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)

    case result do
      count when is_integer(count) -> {:ok, count}
      {:error, _} = error -> error
    end
  end

  defp load_checkpoint(job_name) do
    Repo.get(Checkpoint, job_name)
  end

  defp save_checkpoint(job_name, cursor, count) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    attrs = %{cursor: cursor, last_synced_at: now, records_synced: count}

    case Repo.get(Checkpoint, job_name) do
      nil ->
        %Checkpoint{job_name: job_name}
        |> Checkpoint.changeset(attrs)
        |> Repo.insert()

      existing ->
        existing
        |> Checkpoint.changeset(attrs)
        |> Repo.update()
    end
  end
end
```
