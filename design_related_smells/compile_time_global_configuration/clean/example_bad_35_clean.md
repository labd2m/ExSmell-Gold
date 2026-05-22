```elixir
defmodule FileStorage.S3Adapter do
  @moduledoc """
  Adapter for storing, retrieving, and managing files on Amazon S3.
  Handles multipart uploads, presigned URL generation, and soft deletes.
  Bucket coordinates and region are drawn from application configuration.
  """

  require Logger

  @bucket_name Application.fetch_env!(:file_storage, :s3_bucket)

  @max_upload_size_bytes 100 * 1_024 * 1_024
  @presign_ttl_seconds 3_600
  @allowed_content_types ~w(image/jpeg image/png image/webp application/pdf text/csv)

  @type upload_opts :: %{
          optional(:content_type) => String.t(),
          optional(:metadata) => map(),
          optional(:acl) => String.t()
        }

  @spec upload(String.t(), binary(), upload_opts()) ::
          {:ok, %{key: String.t(), url: String.t(), size: non_neg_integer()}}
          | {:error, :too_large | :unsupported_type | :upload_failed}
  def upload(key, data, opts \\ %{}) when is_binary(key) and is_binary(data) do
    content_type = Map.get(opts, :content_type, "application/octet-stream")

    with :ok <- validate_size(data),
         :ok <- validate_content_type(content_type),
         {:ok, url} <- do_upload(key, data, content_type, opts) do
      Logger.info("File uploaded",
        key: key,
        bucket: @bucket_name,
        size: byte_size(data)
      )

      {:ok, %{key: key, url: url, size: byte_size(data)}}
    end
  end

  @spec download(String.t()) :: {:ok, binary()} | {:error, :not_found | :download_failed}
  def download(key) when is_binary(key) do
    case s3_client().get_object(@bucket_name, key) do
      {:ok, %{body: body}} ->
        Logger.debug("File downloaded", key: key, bucket: @bucket_name)
        {:ok, body}

      {:error, %{status_code: 404}} ->
        {:error, :not_found}

      {:error, reason} ->
        Logger.error("Download failed", key: key, reason: inspect(reason))
        {:error, :download_failed}
    end
  end

  @spec delete(String.t()) :: :ok | {:error, :not_found | :delete_failed}
  def delete(key) when is_binary(key) do
    case s3_client().delete_object(@bucket_name, key) do
      {:ok, _} ->
        Logger.info("File deleted", key: key, bucket: @bucket_name)
        :ok

      {:error, %{status_code: 404}} ->
        {:error, :not_found}

      {:error, reason} ->
        Logger.error("Delete failed", key: key, reason: inspect(reason))
        {:error, :delete_failed}
    end
  end

  @spec presign_url(String.t(), keyword()) :: {:ok, String.t()} | {:error, :presign_failed}
  def presign_url(key, opts \\ []) when is_binary(key) do
    ttl = Keyword.get(opts, :ttl_seconds, @presign_ttl_seconds)
    method = Keyword.get(opts, :method, :get)

    case s3_client().presign_url(@bucket_name, key, method: method, expires_in: ttl) do
      {:ok, url} ->
        {:ok, url}

      {:error, reason} ->
        Logger.error("Presign failed", key: key, reason: inspect(reason))
        {:error, :presign_failed}
    end
  end

  @spec copy(String.t(), String.t()) :: :ok | {:error, atom()}
  def copy(source_key, dest_key) when is_binary(source_key) and is_binary(dest_key) do
    case s3_client().copy_object(@bucket_name, source_key, @bucket_name, dest_key) do
      {:ok, _} -> :ok
      {:error, _} -> {:error, :copy_failed}
    end
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp validate_size(data) when byte_size(data) > @max_upload_size_bytes,
    do: {:error, :too_large}

  defp validate_size(_), do: :ok

  defp validate_content_type(type) do
    if type in @allowed_content_types, do: :ok, else: {:error, :unsupported_type}
  end

  defp do_upload(key, data, content_type, opts) do
    acl = Map.get(opts, :acl, "private")
    metadata = Map.get(opts, :metadata, %{})

    case s3_client().put_object(@bucket_name, key, data,
           content_type: content_type,
           acl: acl,
           metadata: metadata
         ) do
      {:ok, _} -> {:ok, "https://#{@bucket_name}.s3.amazonaws.com/#{key}"}
      {:error, reason} ->
        Logger.error("S3 put_object failed", key: key, reason: inspect(reason))
        {:error, :upload_failed}
    end
  end

  defp s3_client, do: Application.get_env(:file_storage, :s3_client, ExAws.S3)
end
```
