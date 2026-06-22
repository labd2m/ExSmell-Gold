```elixir
defmodule Uploads.StreamProcessor do
  @moduledoc """
  Processes large file uploads as lazy streams, applying transformation
  and validation stages without loading the entire file into memory.
  Supports checksum verification, line-level parsing, and chunked writes
  to object storage.
  """

  alias Uploads.{StorageClient, ChecksumVerifier, UploadRecord, Repo}

  @chunk_size 65_536
  @max_file_size_bytes 104_857_600

  @type upload_opts :: [
          content_type: String.t(),
          expected_checksum: String.t() | nil,
          destination_prefix: String.t()
        ]

  @type process_result :: %{
          key: String.t(),
          bytes_written: non_neg_integer(),
          checksum: String.t(),
          upload_id: String.t()
        }

  @spec process(Plug.Upload.t(), String.t(), upload_opts()) ::
          {:ok, process_result()} | {:error, atom()}
  def process(%Plug.Upload{path: path, filename: filename}, owner_id, opts)
      when is_binary(owner_id) do
    content_type = Keyword.get(opts, :content_type, "application/octet-stream")
    expected_checksum = Keyword.get(opts, :expected_checksum)
    prefix = Keyword.get(opts, :destination_prefix, "uploads")

    with :ok <- check_file_size(path),
         {:ok, checksum} <- compute_checksum(path),
         :ok <- verify_checksum(checksum, expected_checksum),
         {:ok, key, bytes} <- stream_to_storage(path, prefix, filename, content_type),
         {:ok, record} <- persist_record(owner_id, key, bytes, checksum, content_type) do
      {:ok, %{key: key, bytes_written: bytes, checksum: checksum, upload_id: record.id}}
    end
  end

  @spec check_file_size(String.t()) :: :ok | {:error, :file_too_large | :file_not_found}
  defp check_file_size(path) do
    case File.stat(path) do
      {:ok, %File.Stat{size: size}} when size <= @max_file_size_bytes -> :ok
      {:ok, _} -> {:error, :file_too_large}
      {:error, _} -> {:error, :file_not_found}
    end
  end

  @spec compute_checksum(String.t()) :: {:ok, String.t()} | {:error, :checksum_failed}
  defp compute_checksum(path) do
    try do
      hash =
        path
        |> File.stream!([], @chunk_size)
        |> Enum.reduce(:crypto.hash_init(:sha256), &:crypto.hash_update(&2, &1))
        |> :crypto.hash_final()
        |> Base.encode16(case: :lower)

      {:ok, hash}
    rescue
      _ -> {:error, :checksum_failed}
    end
  end

  @spec verify_checksum(String.t(), String.t() | nil) :: :ok | {:error, :checksum_mismatch}
  defp verify_checksum(_actual, nil), do: :ok

  defp verify_checksum(actual, expected) do
    if Plug.Crypto.secure_compare(actual, expected) do
      :ok
    else
      {:error, :checksum_mismatch}
    end
  end

  @spec stream_to_storage(String.t(), String.t(), String.t(), String.t()) ::
          {:ok, String.t(), non_neg_integer()} | {:error, :storage_write_failed}
  defp stream_to_storage(path, prefix, filename, content_type) do
    key = "#{prefix}/#{UUID.uuid4()}/#{sanitize_filename(filename)}"

    stream = File.stream!(path, [], @chunk_size)

    case StorageClient.multipart_upload(key, stream, content_type: content_type) do
      {:ok, bytes_written} -> {:ok, key, bytes_written}
      {:error, _} -> {:error, :storage_write_failed}
    end
  end

  @spec persist_record(String.t(), String.t(), non_neg_integer(), String.t(), String.t()) ::
          {:ok, UploadRecord.t()} | {:error, Ecto.Changeset.t()}
  defp persist_record(owner_id, key, bytes, checksum, content_type) do
    %UploadRecord{}
    |> UploadRecord.creation_changeset(%{
      owner_id: owner_id,
      storage_key: key,
      byte_size: bytes,
      checksum_sha256: checksum,
      content_type: content_type
    })
    |> Repo.insert()
  end

  @spec sanitize_filename(String.t()) :: String.t()
  defp sanitize_filename(filename) do
    filename
    |> String.replace(~r/[^\w.\-]/, "_")
    |> String.slice(0, 200)
  end
end
```
