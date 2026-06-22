```elixir
defmodule Imports.BatchJob do
  @moduledoc """
  Manages the lifecycle of large-batch import jobs with per-row error tracking
  and persisted progress state.

  Import jobs are created, run in chunks, and marked complete or failed.
  Progress is persisted after each chunk so jobs can resume from interruption.
  """

  import Ecto.Query

  alias Imports.Repo
  alias Imports.BatchJob.{Job, RowError, Processor}

  @chunk_size 100

  @type result(t) :: {:ok, t} | {:error, Ecto.Changeset.t() | String.t()}

  @doc """
  Creates a new import job record and returns it for tracking.
  """
  @spec create(String.t(), String.t(), map()) :: result(Job.t())
  def create(name, owner_id, metadata \\ %{})
      when is_binary(name) and is_binary(owner_id) do
    %Job{}
    |> Job.create_changeset(%{name: name, owner_id: owner_id, metadata: metadata, status: :pending})
    |> Repo.insert()
  end

  @doc """
  Runs a job by processing all given rows in chunks.

  Returns `{:ok, job}` on full success or partial completion, or
  `{:error, reason}` on a fatal processor error.
  """
  @spec run(Job.t(), [map()], module()) :: {:ok, Job.t()} | {:error, String.t()}
  def run(%Job{status: :pending} = job, rows, processor_module)
      when is_list(rows) and is_atom(processor_module) do
    total = length(rows)

    with {:ok, started_job} <- mark_running(job, total) do
      process_chunks(started_job, rows, processor_module)
    end
  end

  def run(%Job{status: status}, _, _),
    do: {:error, "cannot run job with status #{status}"}

  @doc """
  Returns all row-level errors for a given job.
  """
  @spec errors_for(String.t()) :: [RowError.t()]
  def errors_for(job_id) when is_binary(job_id) do
    RowError
    |> where([e], e.job_id == ^job_id)
    |> order_by([e], asc: e.row_index)
    |> Repo.all()
  end

  @doc """
  Returns paginated jobs for an owner.
  """
  @spec list_for_owner(String.t(), keyword()) :: [Job.t()]
  def list_for_owner(owner_id, opts \\ []) when is_binary(owner_id) do
    page = Keyword.get(opts, :page, 1)
    per_page = Keyword.get(opts, :per_page, 20)

    Job
    |> where([j], j.owner_id == ^owner_id)
    |> order_by([j], desc: j.inserted_at)
    |> limit(^per_page)
    |> offset(^((page - 1) * per_page))
    |> Repo.all()
  end

  defp process_chunks(job, rows, processor_module) do
    chunks = Enum.chunk_every(rows, @chunk_size)
    total_chunks = length(chunks)

    result =
      chunks
      |> Enum.with_index(1)
      |> Enum.reduce_while({:ok, job}, fn {chunk, chunk_num}, {:ok, current_job} ->
        offset = (chunk_num - 1) * @chunk_size

        {row_errors, processed} = Processor.process_chunk(processor_module, chunk, offset)
        Enum.each(row_errors, &record_row_error(job.id, &1))

        progress = round(chunk_num / total_chunks * 100)

        case update_progress(current_job, current_job.processed_count + processed, progress) do
          {:ok, updated_job} -> {:cont, {:ok, updated_job}}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)

    case result do
      {:ok, final_job} -> finalize(final_job)
      error -> error
    end
  end

  defp mark_running(job, total) do
    job
    |> Job.start_changeset(%{status: :running, total_count: total, started_at: DateTime.utc_now()})
    |> Repo.update()
  end

  defp update_progress(job, processed, progress) do
    job
    |> Job.progress_changeset(%{processed_count: processed, progress_pct: progress})
    |> Repo.update()
  end

  defp finalize(job) do
    error_count =
      RowError
      |> where([e], e.job_id == ^job.id)
      |> Repo.aggregate(:count, :id)

    status = if error_count == 0, do: :complete, else: :complete_with_errors

    job
    |> Job.complete_changeset(%{status: status, completed_at: DateTime.utc_now(), error_count: error_count})
    |> Repo.update()
  end

  defp record_row_error(job_id, %{row_index: idx, reason: reason}) do
    %RowError{}
    |> RowError.changeset(%{job_id: job_id, row_index: idx, reason: reason})
    |> Repo.insert()
  end
end

defmodule Imports.BatchJob.Processor do
  @moduledoc "Behaviour and dispatcher for per-row import processors."

  @callback process_row(map()) :: :ok | {:error, String.t()}

  @spec process_chunk(module(), [map()], non_neg_integer()) ::
          {[%{row_index: non_neg_integer(), reason: String.t()}], non_neg_integer()}
  def process_chunk(module, rows, offset) when is_atom(module) and is_list(rows) do
    {errors, processed} =
      rows
      |> Enum.with_index(offset)
      |> Enum.reduce({[], 0}, fn {row, idx}, {errs, count} ->
        case module.process_row(row) do
          :ok -> {errs, count + 1}
          {:error, reason} -> {[%{row_index: idx, reason: reason} | errs], count + 1}
        end
      end)

    {errors, processed}
  end
end
```
