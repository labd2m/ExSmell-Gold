```elixir
defmodule MyApp.Uploads.MultipartHandler do
  @moduledoc """
  Handles multipart S3-compatible uploads for large files by splitting
  them into parts, uploading each part concurrently through supervised
  Tasks, and finalising the multipart upload on success. On any part
  failure the entire multipart upload is aborted to prevent orphaned
  parts from accumulating in object storage.
  """

  require Logger

  @part_size_bytes 10 * 1024 * 1024
  @max_concurrency 4

  @type upload_id :: String.t()
  @type bucket :: String.t()
  @type object_key :: String.t()

  @type result :: %{
          bucket: bucket(),
          key: object_key(),
          etag: String.t(),
          size_bytes: non_neg_integer()
        }

  @doc """
  Uploads `file_path` to `bucket` under `object_key` using the S3
  multipart upload API. Returns `{:ok, result}` or `{:error, reason}`.
  """
  @spec upload(String.t(), bucket(), object_key()) ::
          {:ok, result()} | {:error, term()}
  def upload(file_path, bucket, object_key)
      when is_binary(file_path) and is_binary(bucket) and is_binary(object_key) do
    with {:ok, file_size} <- file_size(file_path),
         {:ok, upload_id} <- initiate_upload(bucket, object_key),
         {:ok, parts} <- upload_parts(file_path, bucket, object_key, upload_id),
         {:ok, etag} <- complete_upload(bucket, object_key, upload_id, parts) do
      {:ok, %{bucket: bucket, key: object_key, etag: etag, size_bytes: file_size}}
    else
      {:error, reason} = error ->
        maybe_abort_upload(bucket, object_key, reason)
        error
    end
  end

  @spec file_size(String.t()) :: {:ok, non_neg_integer()} | {:error, :file_not_found}
  defp file_size(path) do
    case File.stat(path) do
      {:ok, %{size: size}} -> {:ok, size}
      {:error, _} -> {:error, :file_not_found}
    end
  end

  @spec initiate_upload(bucket(), object_key()) :: {:ok, upload_id()} | {:error, term()}
  defp initiate_upload(bucket, key) do
    MyApp.S3Client.create_multipart_upload(bucket, key)
  end

  @spec upload_parts(String.t(), bucket(), object_key(), upload_id()) ::
          {:ok, [map()]} | {:error, term()}
  defp upload_parts(file_path, bucket, key, upload_id) do
    file_path
    |> stream_chunks()
    |> Stream.with_index(1)
    |> Task.async_stream(
      fn {chunk, part_number} ->
        upload_part(bucket, key, upload_id, part_number, chunk)
      end,
      max_concurrency: @max_concurrency,
      timeout: 60_000,
      on_timeout: :kill_task,
      ordered: true
    )
    |> Enum.reduce_while({:ok, []}, fn
      {:ok, {:ok, part}}, {:ok, acc} -> {:cont, {:ok, [part | acc]}}
      {:ok, {:error, reason}}, _ -> {:halt, {:error, {:part_failed, reason}}}
      {:exit, reason}, _ -> {:halt, {:error, {:part_timeout, reason}}}
    end)
    |> case do
      {:ok, parts} -> {:ok, Enum.reverse(parts)}
      error -> error
    end
  end

  @spec stream_chunks(String.t()) :: Enumerable.t()
  defp stream_chunks(file_path) do
    File.stream!(file_path, @part_size_bytes)
  end

  @spec upload_part(bucket(), object_key(), upload_id(), pos_integer(), binary()) ::
          {:ok, map()} | {:error, term()}
  defp upload_part(bucket, key, upload_id, part_number, chunk) do
    MyApp.S3Client.upload_part(bucket, key, upload_id, part_number, chunk)
  end

  @spec complete_upload(bucket(), object_key(), upload_id(), [map()]) ::
          {:ok, String.t()} | {:error, term()}
  defp complete_upload(bucket, key, upload_id, parts) do
    MyApp.S3Client.complete_multipart_upload(bucket, key, upload_id, parts)
  end

  @spec maybe_abort_upload(bucket(), object_key(), term()) :: :ok
  defp maybe_abort_upload(bucket, key, reason) do
    Logger.warning("multipart_upload_aborted", bucket: bucket, key: key, reason: inspect(reason))
    MyApp.S3Client.abort_multipart_uploads(bucket, key)
    :ok
  end
end
```
