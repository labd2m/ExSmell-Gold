```elixir
defmodule Storage.BlobStore do
  @moduledoc """
  A content-addressable blob store that derives each object's key from a
  SHA-256 digest of its contents. Identical content is stored only once
  regardless of how many times it is uploaded, enabling automatic
  deduplication without application-level checks. Blobs are immutable by
  definition; updating content produces a new digest and a new key.
  Metadata (size, content type, upload count) is tracked in PostgreSQL while
  the binary payload lives in S3.
  """

  alias Storage.{Blob, Repo}
  alias Ecto.Multi

  require Logger

  @type blob_result :: %{
          key: binary(),
          size_bytes: non_neg_integer(),
          content_type: binary(),
          url: binary()
        }

  @doc """
  Stores `content` and returns a `blob_result` map. If the content has been
  stored before the existing blob record is returned without re-uploading.
  Returns `{:ok, blob_result}` or `{:error, reason}`.
  """
  @spec store(binary(), binary()) :: {:ok, blob_result()} | {:error, term()}
  def store(content, content_type)
      when is_binary(content) and is_binary(content_type) do
    key = compute_key(content)

    case Repo.get_by(Blob, content_key: key) do
      %Blob{} = existing ->
        Logger.debug("Blob dedup hit", key: key, size: existing.size_bytes)
        increment_reference(existing)
        {:ok, to_result(existing)}

      nil ->
        upload_and_record(key, content, content_type)
    end
  end

  @doc """
  Retrieves a download URL for the blob identified by `key`.
  Returns `{:error, :not_found}` when no blob with that key exists.
  """
  @spec url_for(binary()) :: {:ok, binary()} | {:error, :not_found}
  def url_for(key) when is_binary(key) do
    case Repo.get_by(Blob, content_key: key) do
      nil -> {:error, :not_found}
      blob -> {:ok, s3_url(blob.content_key)}
    end
  end

  @doc """
  Returns metadata for the blob identified by `key`.
  """
  @spec metadata(binary()) :: {:ok, Blob.t()} | {:error, :not_found}
  def metadata(key) when is_binary(key) do
    case Repo.get_by(Blob, content_key: key) do
      nil -> {:error, :not_found}
      blob -> {:ok, blob}
    end
  end

  @doc """
  Deletes the blob record and removes the object from S3 when the reference
  count reaches zero. Returns `:ok` or `{:error, reason}`.
  """
  @spec delete(binary()) :: :ok | {:error, term()}
  def delete(key) when is_binary(key) do
    case Repo.get_by(Blob, content_key: key) do
      nil ->
        {:error, :not_found}

      %Blob{reference_count: 1} = blob ->
        with :ok <- Storage.S3Client.delete_object(s3_key(key)),
             {:ok, _} <- Repo.delete(blob) do
          :ok
        end

      %Blob{} = blob ->
        blob
        |> Blob.decrement_changeset()
        |> Repo.update()
        |> case do
          {:ok, _} -> :ok
          {:error, reason} -> {:error, reason}
        end
    end
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp compute_key(content) do
    :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)
  end

  defp upload_and_record(key, content, content_type) do
    s3_key = s3_key(key)

    with {:ok, _} <- Storage.S3Client.put_object(s3_key, content,
                       content_type: content_type, acl: :private),
         {:ok, blob} <- insert_blob(key, content, content_type) do
      Logger.info("Blob stored", key: key, size_bytes: blob.size_bytes)
      {:ok, to_result(blob)}
    end
  end

  defp insert_blob(key, content, content_type) do
    %Blob{}
    |> Blob.changeset(%{
      content_key: key,
      content_type: content_type,
      size_bytes: byte_size(content),
      reference_count: 1
    })
    |> Repo.insert()
  end

  defp increment_reference(%Blob{} = blob) do
    blob |> Blob.increment_changeset() |> Repo.update()
  end

  defp to_result(%Blob{} = blob) do
    %{
      key: blob.content_key,
      size_bytes: blob.size_bytes,
      content_type: blob.content_type,
      url: s3_url(blob.content_key)
    }
  end

  defp s3_key(content_key) do
    prefix = String.slice(content_key, 0, 2)
    "blobs/#{prefix}/#{content_key}"
  end

  defp s3_url(content_key) do
    bucket = Application.fetch_env!(:my_app, :s3_bucket)
    "https://#{bucket}.s3.amazonaws.com/#{s3_key(content_key)}"
  end
end
```
