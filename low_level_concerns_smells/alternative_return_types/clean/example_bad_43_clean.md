```elixir
defmodule Assets.FileStore do
  @moduledoc """
  Abstraction over the object storage backend (S3-compatible).
  Provides file upload, retrieval, deletion, and metadata inspection.
  """

  alias Assets.StorageClient
  alias Assets.Repo
  alias Assets.Schema.StoredFile

  @chunk_size 512 * 1024

  @doc """
  Fetches a stored file by its storage key.

  ## Options

    * `:metadata_only` — When `true`, returns a metadata map without
      downloading the file body:
      `%{key: string, size_bytes: integer, content_type: string, etag: string, stored_at: DateTime.t()}`.
    * `:stream` — When `true`, returns a lazy `Stream.t()` that yields
      chunks of the file body. Useful for large files. Overrides default.
    * If neither option is set, returns the full binary body of the file.

  ## Examples

      iex> fetch("uploads/docs/report.pdf")
      <<37, 80, 68, 70, 45, ...>>  # raw binary

      iex> fetch("uploads/docs/report.pdf", metadata_only: true)
      %{key: "uploads/docs/report.pdf", size_bytes: 204800, content_type: "application/pdf", ...}

      iex> fetch("uploads/docs/report.pdf", stream: true)
      #Stream<...>

  """

  def fetch(storage_key, opts \\ []) when is_binary(storage_key) and is_list(opts) do
    record = Repo.get_by!(StoredFile, storage_key: storage_key)

    cond do
      opts[:metadata_only] == true ->
        %{
          key: record.storage_key,
          size_bytes: record.size_bytes,
          content_type: record.content_type,
          etag: record.etag,
          stored_at: record.inserted_at
        }

      opts[:stream] == true ->
        Stream.resource(
          fn -> StorageClient.open_stream(storage_key) end,
          fn conn ->
            case StorageClient.read_chunk(conn, @chunk_size) do
              {:ok, chunk} -> {[chunk], conn}
              :done -> {:halt, conn}
            end
          end,
          fn conn -> StorageClient.close_stream(conn) end
        )

      true ->
        case StorageClient.get_object(storage_key) do
          {:ok, body} -> body
          {:error, reason} -> raise "Failed to fetch #{storage_key}: #{inspect(reason)}"
        end
    end
  end

  @doc """
  Uploads a binary file to the object store and records metadata in the DB.
  """
  def store(binary, filename, content_type) when is_binary(binary) do
    key = generate_storage_key(filename)

    case StorageClient.put_object(key, binary, content_type: content_type) do
      {:ok, etag} ->
        %StoredFile{}
        |> StoredFile.changeset(%{
          storage_key: key,
          original_filename: filename,
          content_type: content_type,
          size_bytes: byte_size(binary),
          etag: etag
        })
        |> Repo.insert()

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Deletes a file from object storage and removes its database record.
  """
  def delete(storage_key) do
    record = Repo.get_by!(StoredFile, storage_key: storage_key)

    with {:ok, _} <- StorageClient.delete_object(storage_key),
         {:ok, _} <- Repo.delete(record) do
      :ok
    end
  end

  defp generate_storage_key(filename) do
    ext = Path.extname(filename)
    uuid = Ecto.UUID.generate()
    "uploads/#{uuid}#{ext}"
  end

  @doc """
  Lists all stored files for a given content type prefix.
  """
  def list_by_type(content_type_prefix) do
    StoredFile
    |> Repo.all()
    |> Enum.filter(&String.starts_with?(&1.content_type, content_type_prefix))
    |> Enum.sort_by(& &1.inserted_at, {:desc, DateTime})
  end
end
```
