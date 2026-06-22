```elixir
defmodule Reports.ExportPipeline do
  @moduledoc """
  Orchestrates asynchronous generation and delivery of large data exports.
  Jobs are submitted to a supervised queue, processed in the background,
  and the resulting file URL is stored in the export record.
  """

  alias Reports.{Repo, ExportJob, DataFetcher, FileSerializer, StorageUploader}

  @type export_request :: %{
          user_id: String.t(),
          report_type: atom(),
          filters: map(),
          format: :csv | :json
        }

  @spec request_export(export_request()) :: {:ok, ExportJob.t()} | {:error, Ecto.Changeset.t()}
  def request_export(params) do
    %ExportJob{}
    |> ExportJob.creation_changeset(params)
    |> Repo.insert()
    |> case do
      {:ok, job} ->
        enqueue(job)
        {:ok, job}

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  @spec process(ExportJob.t()) :: :ok | {:error, atom()}
  def process(%ExportJob{} = job) do
    with {:ok, _} <- mark_processing(job),
         {:ok, rows} <- DataFetcher.fetch(job.report_type, job.filters),
         {:ok, binary} <- FileSerializer.serialize(rows, job.format),
         {:ok, url} <- StorageUploader.upload(binary, filename(job)),
         {:ok, _} <- mark_completed(job, url) do
      :ok
    else
      {:error, reason} ->
        mark_failed(job, reason)
        {:error, reason}
    end
  end

  @spec enqueue(ExportJob.t()) :: :ok
  defp enqueue(job) do
    Oban.insert!(Reports.ExportWorker.new(%{job_id: job.id}))
    :ok
  end

  @spec mark_processing(ExportJob.t()) :: {:ok, ExportJob.t()} | {:error, Ecto.Changeset.t()}
  defp mark_processing(job) do
    job
    |> ExportJob.status_changeset(:processing, %{started_at: DateTime.utc_now()})
    |> Repo.update()
  end

  @spec mark_completed(ExportJob.t(), String.t()) ::
          {:ok, ExportJob.t()} | {:error, Ecto.Changeset.t()}
  defp mark_completed(job, url) do
    job
    |> ExportJob.status_changeset(:completed, %{
      file_url: url,
      completed_at: DateTime.utc_now()
    })
    |> Repo.update()
  end

  @spec mark_failed(ExportJob.t(), atom()) :: :ok
  defp mark_failed(job, reason) do
    job
    |> ExportJob.status_changeset(:failed, %{failure_reason: to_string(reason)})
    |> Repo.update()

    :ok
  end

  @spec filename(ExportJob.t()) :: String.t()
  defp filename(job) do
    ts = DateTime.to_unix(DateTime.utc_now())
    "exports/#{job.report_type}_#{job.id}_#{ts}.#{job.format}"
  end
end
```
