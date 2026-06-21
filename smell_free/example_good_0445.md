```elixir
defmodule Storage.MultipartUploader do
  @moduledoc """
  Uploads large binary payloads to Amazon S3 using the multipart upload API.
  The payload is split into configurable-size parts and each part is uploaded
  concurrently via a `Task.Supervisor`. If any part fails the upload is
  aborted, triggering S3 to release all partial data. This avoids both
  loading the entire file into memory and retrying from byte zero on failure.
  """

  alias Storage.S3Client

  require Logger

  @min_part_size_bytes 5 * 1024 * 1024
  @default_part_size_bytes 10 * 1024 * 1024
  @max_concurrency 8

  @type upload_opts :: [
          bucket: binary(),
          key: binary(),
          content_type: binary(),
          part_size_bytes: pos_integer()
        ]

  @doc """
  Uploads `binary` to S3 at `bucket/key` using multipart upload.
  Splits the binary into parts of `:part_size_bytes` (minimum 5 MB) and
  uploads them concurrently. Returns `{:ok, etag}` on success or
  `{:error, reason}` after aborting the multipart session.
  """
  @spec upload(binary(), upload_opts()) :: {:ok, binary()} | {:error, term()}
  def upload(binary, opts) when is_binary(binary) do
    bucket = Keyword.fetch!(opts, :bucket)
    key = Keyword.fetch!(opts, :key)
    content_type = Keyword.get(opts, :content_type, "application/octet-stream")
    part_size = Keyword.get(opts, :part_size_bytes, @default_part_size_bytes)
              |> max(@min_part_size_bytes)

    with {:ok, upload_id} <- S3Client.create_multipart_upload(bucket, key, content_type),
         {:ok, parts} <- upload_parts(binary, bucket, key, upload_id, part_size),
         {:ok, etag} <- S3Client.complete_multipart_upload(bucket, key, upload_id, parts) do
      Logger.info("Multipart upload complete",
        bucket: bucket,
        key: key,
        size_bytes: byte_size(binary),
        parts: length(parts)
      )

      {:ok, etag}
    else
      {:error, reason} = err ->
        Logger.error("Multipart upload failed, aborting", bucket: bucket, key: key, reason: inspect(reason))
        maybe_abort(bucket, key, reason)
        err
    end
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp upload_parts(binary, bucket, key, upload_id, part_size) do
    parts = split_into_parts(binary, part_size)
    total = length(parts)

    Logger.info("Uploading in parts", bucket: bucket, key: key, part_count: total, part_size_bytes: part_size)

    results =
      parts
      |> Enum.with_index(1)
      |> Task.async_stream(
        fn {part_data, part_number} ->
          case S3Client.upload_part(bucket, key, upload_id, part_number, part_data) do
            {:ok, etag} ->
              {:ok, %{part_number: part_number, etag: etag}}

            {:error, reason} ->
              Logger.warning("Part upload failed",
                part_number: part_number,
                total_parts: total,
                reason: inspect(reason)
              )
              {:error, {:part_failed, part_number, reason}}
          end
        end,
        max_concurrency: @max_concurrency,
        timeout: 120_000,
        on_timeout: :kill_task
      )
      |> Enum.to_list()

    collect_part_results(results)
  end

  defp collect_part_results(results) do
    {oks, errors} =
      Enum.split_with(results, fn
        {:ok, {:ok, _}} -> true
        _ -> false
      end)

    case errors do
      [] ->
        parts =
          oks
          |> Enum.map(fn {:ok, {:ok, part}} -> part end)
          |> Enum.sort_by(& &1.part_number)

        {:ok, parts}

      [{:ok, {:error, reason}} | _] ->
        {:error, reason}

      [{:exit, :timeout} | _] ->
        {:error, :part_upload_timeout}

      [{:exit, reason} | _] ->
        {:error, {:part_exit, reason}}
    end
  end

  defp split_into_parts(binary, part_size) do
    binary
    |> :binary.bin_to_list()
    |> Enum.chunk_every(part_size)
    |> Enum.map(&:binary.list_to_bin/1)
  end

  defp maybe_abort(bucket, key, {:upload_id, upload_id}) do
    S3Client.abort_multipart_upload(bucket, key, upload_id)
  end

  defp maybe_abort(_bucket, _key, _reason), do: :ok
end
```
