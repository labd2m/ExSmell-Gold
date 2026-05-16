```elixir
defmodule Documents.UploadPipeline do
  alias Documents.{Repo, Document, VirusScanner, MetadataExtractor, SearchIndex, CollaboratorNotifier}

  require Logger

  @allowed_mime_types ~w[
    application/pdf
    application/vnd.openxmlformats-officedocument.wordprocessingml.document
    text/plain
    image/png
    image/jpeg
  ]

  def process_upload(upload, workspace_id, uploader_id) do
    with {:ok, scan_result} <- VirusScanner.scan(upload.path),
         :ok <- validate_mime_type(upload.content_type),
         {:ok, metadata} <- MetadataExtractor.extract(upload.path, upload.content_type),
         {:ok, document} <- persist_document(upload, metadata, workspace_id, uploader_id),
         {:ok, _index_id} <- SearchIndex.index(document),
         :ok <- CollaboratorNotifier.notify_upload(document, workspace_id) do
      Logger.info(
        "Document uploaded: #{document.id} to workspace #{workspace_id} " <>
          "by #{uploader_id} (pages=#{metadata[:page_count]})"
      )

      {:ok, document}
    else
      {:error, :virus_detected} ->
        Logger.warning("Virus detected in upload from #{uploader_id}: #{upload.filename}")
        {:error, :upload_rejected}

      {:error, :scan_failed} ->
        Logger.error("Virus scan failed for upload from #{uploader_id}")
        {:error, :scan_unavailable}

      {:error, :unsupported_type} ->
        Logger.warning("Unsupported MIME type #{upload.content_type} from #{uploader_id}")
        {:error, :unsupported_file_type}

      {:error, {:metadata_error, reason}} ->
        Logger.error("Metadata extraction failed for #{upload.filename}: #{inspect(reason)}")
        {:error, :metadata_extraction_failed}

      {:error, {:db_error, changeset}} ->
        Logger.error("Document persistence failed: #{inspect(changeset.errors)}")
        {:error, :storage_error}

      {:error, :index_unavailable} ->
        Logger.error("Search index unavailable — document stored but not searchable")
        {:error, :indexing_failed}

      {:error, :notification_failed} ->
        Logger.warning("Collaborator notification failed for document in workspace #{workspace_id}")
        {:error, :notification_error}

      {:error, reason} ->
        Logger.error("Unexpected upload error: #{inspect(reason)}")
        {:error, :internal_error}
    end
  end

  defp validate_mime_type(content_type) do
    if content_type in @allowed_mime_types do
      :ok
    else
      {:error, :unsupported_type}
    end
  end

  defp persist_document(upload, metadata, workspace_id, uploader_id) do
    %Document{}
    |> Document.changeset(%{
      filename: upload.filename,
      content_type: upload.content_type,
      size_bytes: upload.size,
      page_count: metadata[:page_count],
      workspace_id: workspace_id,
      uploaded_by: uploader_id,
      storage_path: upload.path,
      status: :active
    })
    |> Repo.insert()
    |> case do
      {:ok, doc} -> {:ok, doc}
      {:error, cs} -> {:error, {:db_error, cs}}
    end
  end
end
```
