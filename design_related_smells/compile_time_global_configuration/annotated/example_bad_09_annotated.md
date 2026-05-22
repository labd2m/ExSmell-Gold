# Annotated Bad Example 09

## Metadata

- **Smell name:** Compile-time global configuration
- **Expected smell location:** Module attribute `@s3_bucket` defined at the top of `Storage.S3Client`
- **Affected function(s):** `upload_file/3`, `download_file/2`, `delete_file/1`, `presigned_url/2`
- **Short explanation:** `Application.fetch_env!/2` is invoked in the module body, which runs at compile-time. The Application Environment for `:storage` may not yet be loaded during compilation, causing a warning or `ArgumentError` to be raised by the compiler.

---

```elixir
defmodule Storage.S3Client do
  @moduledoc """
  Provides file upload, download, deletion, and presigned-URL generation
  for objects stored in Amazon S3. All paths are relative to the configured
  bucket. Large uploads are automatically streamed in multipart chunks.
  """

  require Logger

  @multipart_threshold_bytes 5 * 1024 * 1024
  @presigned_url_default_ttl 3_600

  # VALIDATION: SMELL START - Compile-time global configuration
  # VALIDATION: This is a smell because Application.fetch_env!/2 is called in the
  # VALIDATION: module body to set a module attribute. Module attributes are resolved
  # VALIDATION: at compile-time; at that moment, the :storage OTP application and its
  # VALIDATION: configuration may not have been loaded yet, triggering a warning or
  # VALIDATION: ArgumentError during compilation.
  @s3_bucket Application.fetch_env!(:storage, :s3_bucket)
  # VALIDATION: SMELL END

  @type s3_key :: String.t()
  @type upload_opts :: [content_type: String.t(), metadata: map()]

  @doc """
  Uploads binary `content` to S3 at the given `key`.

  Automatically selects multipart upload for files larger than
  #{@multipart_threshold_bytes} bytes.

  ## Parameters
    - `key` - S3 object key (path within the bucket).
    - `content` - Binary content to store.
    - `opts` - Optional keyword list with `:content_type` and `:metadata`.
  """
  @spec upload_file(s3_key(), binary(), upload_opts()) ::
          {:ok, %{bucket: String.t(), key: s3_key(), etag: String.t()}}
          | {:error, term()}
  def upload_file(key, content, opts \\ []) when is_binary(key) and is_binary(content) do
    content_type = Keyword.get(opts, :content_type, "application/octet-stream")
    metadata = Keyword.get(opts, :metadata, %{})
    size = byte_size(content)

    Logger.info("Uploading file bucket=#{@s3_bucket} key=#{key} size=#{size}")

    result =
      if size > @multipart_threshold_bytes do
        do_multipart_upload(key, content, content_type, metadata)
      else
        do_put_object(key, content, content_type, metadata)
      end

    case result do
      {:ok, etag} ->
        Logger.info("Upload complete bucket=#{@s3_bucket} key=#{key} etag=#{etag}")
        {:ok, %{bucket: @s3_bucket, key: key, etag: etag}}

      {:error, _} = err ->
        Logger.error("Upload failed bucket=#{@s3_bucket} key=#{key}")
        err
    end
  end

  @doc """
  Downloads the object at `key` from S3 and returns its binary content.
  """
  @spec download_file(s3_key(), keyword()) :: {:ok, binary()} | {:error, term()}
  def download_file(key, _opts \\ []) when is_binary(key) do
    Logger.info("Downloading file bucket=#{@s3_bucket} key=#{key}")
    Storage.AWSAdapter.get_object(@s3_bucket, key)
  end

  @doc """
  Permanently deletes the object at `key`.
  """
  @spec delete_file(s3_key()) :: :ok | {:error, term()}
  def delete_file(key) when is_binary(key) do
    Logger.info("Deleting file bucket=#{@s3_bucket} key=#{key}")

    case Storage.AWSAdapter.delete_object(@s3_bucket, key) do
      :ok ->
        Logger.info("Deleted bucket=#{@s3_bucket} key=#{key}")
        :ok

      {:error, reason} = err ->
        Logger.error("Delete failed bucket=#{@s3_bucket} key=#{key} reason=#{inspect(reason)}")
        err
    end
  end

  @doc """
  Generates a time-limited presigned URL for direct client access to `key`.

  ## Parameters
    - `key` - The S3 object key.
    - `ttl_seconds` - How long the URL stays valid; defaults to #{@presigned_url_default_ttl}s.
  """
  @spec presigned_url(s3_key(), pos_integer()) :: {:ok, String.t()} | {:error, term()}
  def presigned_url(key, ttl_seconds \\ @presigned_url_default_ttl) when is_binary(key) do
    Logger.debug("Generating presigned URL bucket=#{@s3_bucket} key=#{key} ttl=#{ttl_seconds}")
    Storage.AWSAdapter.presign_url(@s3_bucket, key, ttl_seconds)
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp do_put_object(key, content, content_type, metadata) do
    Storage.AWSAdapter.put_object(@s3_bucket, key, content,
      content_type: content_type,
      metadata: metadata
    )
  end

  defp do_multipart_upload(key, content, content_type, metadata) do
    chunk_size = @multipart_threshold_bytes

    chunks =
      content
      |> Stream.unfold(fn
        <<>> -> nil
        data -> {binary_part(data, 0, min(byte_size(data), chunk_size)),
                 binary_part(data, min(byte_size(data), chunk_size), max(byte_size(data) - chunk_size, 0))}
      end)
      |> Enum.to_list()

    Storage.AWSAdapter.multipart_upload(@s3_bucket, key, chunks,
      content_type: content_type,
      metadata: metadata
    )
  end
end
```
