```elixir
defmodule Media.UploadProcessor do
  @moduledoc """
  Orchestrates the full lifecycle of a user file upload: validates the
  content type and size, submits the payload to an antivirus scanner,
  derives a deterministic storage key, and transfers the file to S3.
  Each stage is isolated to a private function, keeping the public
  surface minimal and making the pipeline straightforward to test by
  substituting any single stage.
  """

  alias Media.{FileMetadata, StorageClient, VirusScanner}

  require Logger

  @type upload_input :: %{
          required(:filename) => String.t(),
          required(:content_type) => String.t(),
          required(:body) => binary(),
          required(:uploaded_by) => binary()
        }

  @type upload_result :: %{
          key: String.t(),
          filename: String.t(),
          content_type: String.t(),
          size_bytes: non_neg_integer(),
          etag: String.t()
        }

  @max_file_size_bytes 50 * 1024 * 1024
  @allowed_content_types ~w[
    image/jpeg image/png image/webp image/gif
    application/pdf
    text/csv text/plain
    application/zip
  ]

  @doc """
  Processes a raw upload through validation, scanning, and storage.
  Returns `{:ok, upload_result}` on success or `{:error, reason}` on
  any failure. Logging is performed at each stage for auditability.
  """
  @spec process(upload_input()) :: {:ok, upload_result()} | {:error, term()}
  def process(%{filename: filename, content_type: ct, body: body, uploaded_by: user_id} = input)
      when is_binary(filename) and is_binary(ct) and is_binary(body) and is_binary(user_id) do
    with :ok <- validate_content_type(ct),
         :ok <- validate_size(body),
         :ok <- scan_for_threats(body, filename),
         {:ok, key} <- build_storage_key(input),
         {:ok, etag} <- store(key, body, ct) do
      result = %{
        key: key,
        filename: filename,
        content_type: ct,
        size_bytes: byte_size(body),
        etag: etag
      }

      Logger.info("File uploaded successfully",
        filename: filename,
        key: key,
        uploaded_by: user_id,
        size_bytes: result.size_bytes
      )

      {:ok, result}
    else
      {:error, reason} = err ->
        Logger.warning("Upload failed",
          filename: filename,
          uploaded_by: user_id,
          reason: inspect(reason)
        )

        err
    end
  end

  def process(_input), do: {:error, :invalid_params}

  # ---------------------------------------------------------------------------
  # Private pipeline stages
  # ---------------------------------------------------------------------------

  defp validate_content_type(content_type) when content_type in @allowed_content_types, do: :ok
  defp validate_content_type(ct), do: {:error, {:unsupported_content_type, ct}}

  defp validate_size(body) when byte_size(body) <= @max_file_size_bytes, do: :ok
  defp validate_size(_body), do: {:error, {:file_too_large, @max_file_size_bytes}}

  defp scan_for_threats(body, filename) do
    case VirusScanner.scan(body) do
      :clean -> :ok
      {:threat, signature} -> {:error, {:threat_detected, filename, signature}}
      {:error, reason} -> {:error, {:scan_service_error, reason}}
    end
  end

  defp build_storage_key(%{filename: filename, uploaded_by: user_id}) do
    ext = Path.extname(filename)
    hash = :crypto.hash(:sha256, filename <> user_id <> inspect(System.unique_integer())) |> Base.encode16(case: :lower)
    date_prefix = Date.utc_today() |> Date.to_string() |> String.replace("-", "/")
    {:ok, "uploads/#{date_prefix}/#{hash}#{ext}"}
  end

  defp store(key, body, content_type) do
    opts = [content_type: content_type, acl: :private, server_side_encryption: "AES256"]

    case StorageClient.put_object(key, body, opts) do
      {:ok, %{etag: etag}} -> {:ok, etag}
      {:error, reason} -> {:error, {:storage_failed, reason}}
    end
  end
end
```
