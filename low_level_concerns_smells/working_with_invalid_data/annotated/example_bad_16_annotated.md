# Code Smell Annotation

- **Smell name:** Working with invalid data
- **Expected smell location:** `FileUploadHandler.process/3`, where `max_size_bytes` is used in a comparison with `file_size`
- **Affected function(s):** `process/3`
- **Short explanation:** The `max_size_bytes` option is extracted from opts and used in the comparison `file_size > max_size_bytes` without verifying that it is an integer. If a caller passes a string (e.g., from an environment variable that was not parsed) such as `"5242880"`, the Erlang comparison of an integer against a binary raises a `BadArgumentError` inside the runtime, obscuring the actual source of the problem.

```elixir
defmodule MyApp.Storage.FileUploadHandler do
  @moduledoc """
  Handles file upload processing including validation, virus scanning,
  format normalization, and persistence to the configured object store.
  """

  require Logger

  alias MyApp.Storage.{ObjectStore, UploadRecord, VirusScanner}
  alias MyApp.Accounts.User

  @default_max_size_bytes 10 * 1024 * 1024
  @allowed_mime_types ~w(
    image/jpeg image/png image/webp image/gif
    application/pdf
    text/plain text/csv
    application/vnd.openxmlformats-officedocument.spreadsheetml.sheet
  )
  @quarantine_bucket "uploads-quarantine"
  @permanent_bucket "uploads-permanent"

  @type upload_opts :: [
          max_size_bytes: pos_integer(),
          allowed_types: [String.t()],
          scan_for_viruses: boolean(),
          prefix: String.t()
        ]

  @spec process(User.t(), map(), upload_opts()) ::
          {:ok, UploadRecord.t()} | {:error, atom()}
  def process(uploader, file_params, opts \\ []) do
    allowed_types = Keyword.get(opts, :allowed_types, @allowed_mime_types)
    scan = Keyword.get(opts, :scan_for_viruses, true)
    prefix = Keyword.get(opts, :prefix, "uploads")

    file_path = file_params.path
    file_name = file_params.filename
    content_type = file_params.content_type
    file_size = file_params.size

    max_size_bytes = Keyword.get(opts, :max_size_bytes, @default_max_size_bytes)

    # VALIDATION: SMELL START - Working with invalid data
    # VALIDATION: This is a smell because `max_size_bytes` is used directly in
    # VALIDATION: the comparison `file_size > max_size_bytes` without checking
    # VALIDATION: that it is an integer. If the calling code reads this value from
    # VALIDATION: an environment variable or config without parsing (e.g. System.get_env/1
    # VALIDATION: returns a string), the comparison of integer > binary will raise
    # VALIDATION: a BadArgumentError inside Erlang's comparison operator.
    if file_size > max_size_bytes do
      # VALIDATION: SMELL END
      Logger.warning("Upload rejected: file too large (#{file_size} > #{max_size_bytes})")
      {:error, :file_too_large}
    else
      with :ok <- validate_mime_type(content_type, allowed_types),
           :ok <- validate_filename(file_name),
           {:ok, scan_result} <- maybe_scan(file_path, scan),
           {:ok, stored_key} <- store_file(file_path, file_name, prefix, uploader.id) do
        record = %{
          id: Ecto.UUID.generate(),
          uploader_id: uploader.id,
          original_filename: file_name,
          stored_key: stored_key,
          content_type: content_type,
          size_bytes: file_size,
          bucket: determine_bucket(scan_result),
          virus_scan_result: scan_result,
          uploaded_at: DateTime.utc_now()
        }

        case UploadRecord.insert(record) do
          {:ok, upload} ->
            Logger.info("File uploaded: key=#{stored_key} size=#{file_size} user=#{uploader.id}")
            {:ok, upload}

          {:error, _} ->
            ObjectStore.delete(stored_key)
            {:error, :record_creation_failed}
        end
      end
    end
  end

  @spec delete_upload(String.t(), User.t()) :: :ok | {:error, atom()}
  def delete_upload(upload_id, requester) do
    with {:ok, record} <- UploadRecord.fetch(upload_id),
         :ok <- authorize_deletion(record, requester) do
      ObjectStore.delete(record.stored_key)
      UploadRecord.mark_deleted(upload_id)
    end
  end

  @spec generate_download_url(String.t(), pos_integer()) ::
          {:ok, String.t()} | {:error, atom()}
  def generate_download_url(upload_id, ttl_seconds \\ 3600) do
    with {:ok, record} <- UploadRecord.fetch(upload_id) do
      ObjectStore.presign_url(record.stored_key, ttl_seconds)
    end
  end

  # Private helpers

  defp validate_mime_type(content_type, allowed) do
    if content_type in allowed do
      :ok
    else
      {:error, :unsupported_mime_type}
    end
  end

  defp validate_filename(name) do
    if String.match?(name, ~r/^[a-zA-Z0-9_\-. ]{1,255}$/) do
      :ok
    else
      {:error, :invalid_filename}
    end
  end

  defp maybe_scan(path, true), do: VirusScanner.scan(path)
  defp maybe_scan(_path, false), do: {:ok, :skipped}

  defp store_file(path, name, prefix, user_id) do
    ext = Path.extname(name)
    key = "#{prefix}/#{user_id}/#{Ecto.UUID.generate()}#{ext}"
    ObjectStore.put(path, key)
  end

  defp determine_bucket(:clean), do: @permanent_bucket
  defp determine_bucket(:skipped), do: @permanent_bucket
  defp determine_bucket(_), do: @quarantine_bucket

  defp authorize_deletion(%{uploader_id: uid}, %{id: uid}), do: :ok
  defp authorize_deletion(_record, _requester), do: {:error, :unauthorized}
end
```
