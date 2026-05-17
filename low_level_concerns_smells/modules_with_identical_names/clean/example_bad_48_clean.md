```elixir
# ── file: lib/export/pipeline.ex ────────────────────────────────────────────

defmodule Export.Pipeline do
  @moduledoc """
  Manages data export jobs: queuing, execution, and download link generation.
  Defined in `lib/export/pipeline.ex`.
  """

  alias Export.{JobStore, Formatter, StorageBackend, JobQueue, NotificationBus}

  @supported_formats [:csv, :xlsx, :json, :parquet]
  @export_ttl_hours 48
  @max_rows 1_000_000

  @type job_id :: String.t()

  @type export_job :: %{
    id: job_id(),
    requester_id: String.t(),
    resource: String.t(),
    filters: map(),
    format: atom(),
    status: :queued | :running | :completed | :failed | :expired,
    row_count: non_neg_integer() | nil,
    storage_key: String.t() | nil,
    error: String.t() | nil,
    created_at: DateTime.t(),
    completed_at: DateTime.t() | nil
  }

  @doc """
  Execute an export job synchronously. Intended for small exports.
  For large datasets, prefer `enqueue/2`.
  """
  @spec run(String.t(), map()) :: {:ok, export_job()} | {:error, String.t()}
  def run(resource, opts) do
    format = Map.get(opts, :format, :csv)
    filters = Map.get(opts, :filters, %{})
    requester_id = Map.get(opts, :requester_id, "system")

    unless format in @supported_formats do
      {:error, "Unsupported format: #{format}"}
    else
      job = build_job(resource, format, filters, requester_id)

      with {:ok, data_stream} <- fetch_data(resource, filters),
           :ok <- check_row_limit(data_stream),
           {:ok, binary} <- Formatter.format(data_stream, format),
           {:ok, storage_key} <- StorageBackend.upload(binary, export_path(job)) do
        completed = %{
          job
          | status: :completed,
            row_count: length(data_stream),
            storage_key: storage_key,
            completed_at: DateTime.utc_now()
        }

        JobStore.save(completed)
        {:ok, completed}
      else
        {:error, reason} ->
          failed = %{job | status: :failed, error: inspect(reason)}
          JobStore.save(failed)
          {:error, inspect(reason)}
      end
    end
  end

  @doc "Enqueue a large export job for background execution."
  @spec enqueue(String.t(), map()) :: {:ok, job_id()} | {:error, String.t()}
  def enqueue(resource, opts) do
    format = Map.get(opts, :format, :csv)

    unless format in @supported_formats do
      {:error, "Unsupported format: #{format}"}
    else
      job = build_job(resource, format, Map.get(opts, :filters, %{}), Map.get(opts, :requester_id))
      {:ok, _} = JobStore.save(job)
      :ok = JobQueue.push(job.id)
      {:ok, job.id}
    end
  end

  @doc "Return the current status of an export job."
  @spec status(job_id()) :: {:ok, atom()} | {:error, String.t()}
  def status(job_id) do
    case JobStore.fetch(job_id) do
      {:ok, %{status: s}} -> {:ok, s}
      :not_found -> {:error, "Export job not found: #{job_id}"}
    end
  end

  @doc "Generate a pre-signed download URL for a completed export."
  @spec download_url(job_id()) :: {:ok, String.t()} | {:error, String.t()}
  def download_url(job_id) do
    case JobStore.fetch(job_id) do
      {:ok, %{status: :completed, storage_key: key}} ->
        ttl = @export_ttl_hours * 3600
        StorageBackend.presign_url(key, ttl: ttl)

      {:ok, %{status: s}} ->
        {:error, "Cannot download export in status: #{s}"}

      :not_found ->
        {:error, "Export job not found: #{job_id}"}
    end
  end

  @doc "Cancel a queued export job before it begins execution."
  @spec cancel(job_id()) :: :ok | {:error, String.t()}
  def cancel(job_id) do
    case JobStore.fetch(job_id) do
      {:ok, %{status: :queued} = job} ->
        JobQueue.remove(job_id)
        JobStore.update(job.id, %{status: :failed, error: "cancelled_by_user"})

      {:ok, %{status: s}} ->
        {:error, "Cannot cancel export in status: #{s}"}

      :not_found ->
        {:error, "Export job not found: #{job_id}"}
    end
  end

  defp build_job(resource, format, filters, requester_id) do
    %{
      id: generate_id(),
      requester_id: requester_id,
      resource: resource,
      filters: filters,
      format: format,
      status: :queued,
      row_count: nil,
      storage_key: nil,
      error: nil,
      created_at: DateTime.utc_now(),
      completed_at: nil
    }
  end

  defp fetch_data(resource, filters) do
    Export.DataSource.query(resource, filters)
  end

  defp check_row_limit(rows) when length(rows) > @max_rows do
    {:error, "Export exceeds row limit of #{@max_rows}"}
  end

  defp check_row_limit(_rows), do: :ok

  defp export_path(%{id: id, format: fmt}), do: "exports/#{id}.#{fmt}"

  defp generate_id, do: :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
end


# ── file: lib/export/pipeline_cleanup.ex  

defmodule Export.Pipeline do
  @moduledoc """
  Cleanup and expiry management for completed export jobs and their storage.
  Was intended to be `Export.Pipeline.Cleanup` but was accidentally given
  the same module name as the core export pipeline.
  """

  alias Export.{JobStore, StorageBackend}

  @retention_hours 48

  @doc "Delete completed export files and job records older than the retention window."
  @spec purge_expired() :: {:ok, non_neg_integer()}
  def purge_expired do
    cutoff = DateTime.add(DateTime.utc_now(), -@retention_hours * 3600, :second)

    expired =
      JobStore.all(status: :completed)
      |> Enum.filter(&(DateTime.compare(&1.completed_at, cutoff) == :lt))

    Enum.each(expired, fn job ->
      if job.storage_key, do: StorageBackend.delete(job.storage_key)
      JobStore.update(job.id, %{status: :expired})
    end)

    {:ok, length(expired)}
  end

  @doc "Delete the storage artefact for a single completed job."
  @spec delete_file(String.t()) :: :ok | {:error, String.t()}
  def delete_file(job_id) do
    case JobStore.fetch(job_id) do
      {:ok, %{storage_key: key}} when is_binary(key) ->
        StorageBackend.delete(key)

      {:ok, _} ->
        {:error, "Job has no associated file"}

      :not_found ->
        {:error, "Export job not found: #{job_id}"}
    end
  end

  @doc "Return storage usage statistics for all active export files."
  @spec storage_stats() :: map()
  def storage_stats do
    jobs = JobStore.all(status: :completed)

    total_bytes =
      jobs
      |> Enum.map(fn job ->
        case StorageBackend.file_size(job.storage_key) do
          {:ok, size} -> size
          _ -> 0
        end
      end)
      |> Enum.sum()

    %{file_count: length(jobs), total_bytes: total_bytes, total_mb: Float.round(total_bytes / 1_048_576, 2)}
  end
end

```
