# File: `example_good_962.md`

```elixir
defmodule Storage.VersionedObject do
  @moduledoc """
  Manages versioned binary objects with immutable content-addressed
  storage semantics. Each write creates a new version; no version is
  ever mutated or deleted except through explicit lifecycle operations.

  Objects are identified by a logical key. Multiple versions coexist
  under the same key, with the most recently written treated as current.
  """

  import Ecto.Query, warn: false

  alias Storage.{ObjectVersion, Repo}

  @type object_key :: String.t()
  @type version_id :: Ecto.UUID.t()
  @type content :: binary()

  @type version_metadata :: %{
          version_id: version_id(),
          object_key: object_key(),
          content_hash: String.t(),
          content_type: String.t(),
          size_bytes: non_neg_integer(),
          stored_at: DateTime.t(),
          metadata: map()
        }

  @doc """
  Stores `content` as a new version under `object_key`.

  Returns `{:ok, version_metadata}`. The content hash is computed
  automatically for integrity verification.
  """
  @spec put(object_key(), content(), String.t(), map()) ::
          {:ok, version_metadata()} | {:error, Ecto.Changeset.t()}
  def put(object_key, content, content_type, metadata \\ %{})
      when is_binary(object_key) and is_binary(content) and is_binary(content_type) do
    hash = content_hash(content)

    attrs = %{
      object_key: object_key,
      content: content,
      content_type: content_type,
      content_hash: hash,
      size_bytes: byte_size(content),
      metadata: metadata,
      stored_at: DateTime.utc_now()
    }

    case attrs |> ObjectVersion.changeset() |> Repo.insert() do
      {:ok, record} -> {:ok, to_metadata(record)}
      {:error, _} = error -> error
    end
  end

  @doc """
  Returns the content of the most recent version of `object_key`.

  Returns `{:ok, content}` or `{:error, :not_found}`.
  """
  @spec get(object_key()) :: {:ok, content()} | {:error, :not_found}
  def get(object_key) when is_binary(object_key) do
    case latest_record(object_key) do
      nil -> {:error, :not_found}
      record -> {:ok, record.content}
    end
  end

  @doc """
  Returns the metadata for the most recent version without fetching content.
  """
  @spec head(object_key()) :: {:ok, version_metadata()} | {:error, :not_found}
  def head(object_key) when is_binary(object_key) do
    case latest_record(object_key) do
      nil -> {:error, :not_found}
      record -> {:ok, to_metadata(record)}
    end
  end

  @doc """
  Returns the content of a specific historical version by `version_id`.
  """
  @spec get_version(version_id()) :: {:ok, content()} | {:error, :not_found}
  def get_version(version_id) when is_binary(version_id) do
    case Repo.get(ObjectVersion, version_id) do
      nil -> {:error, :not_found}
      record -> {:ok, record.content}
    end
  end

  @doc """
  Returns metadata for all versions of `object_key`, newest first.
  """
  @spec list_versions(object_key()) :: [version_metadata()]
  def list_versions(object_key) when is_binary(object_key) do
    ObjectVersion
    |> where([v], v.object_key == ^object_key)
    |> select([v], map(v, [:id, :object_key, :content_hash, :content_type, :size_bytes, :stored_at, :metadata]))
    |> order_by([v], desc: v.stored_at)
    |> Repo.all()
    |> Enum.map(fn row -> %{version_id: row.id, object_key: row.object_key,
                             content_hash: row.content_hash, content_type: row.content_type,
                             size_bytes: row.size_bytes, stored_at: row.stored_at,
                             metadata: row.metadata} end)
  end

  @doc """
  Deletes all versions of `object_key` older than `keep_versions` most recent.

  Returns the count of deleted versions.
  """
  @spec prune_old_versions(object_key(), pos_integer()) :: non_neg_integer()
  def prune_old_versions(object_key, keep_versions)
      when is_binary(object_key) and is_integer(keep_versions) and keep_versions > 0 do
    ids_to_keep =
      ObjectVersion
      |> where([v], v.object_key == ^object_key)
      |> order_by([v], desc: v.stored_at)
      |> limit(^keep_versions)
      |> select([v], v.id)
      |> Repo.all()

    {count, _} =
      ObjectVersion
      |> where([v], v.object_key == ^object_key and v.id not in ^ids_to_keep)
      |> Repo.delete_all()

    count
  end

  @doc """
  Verifies the integrity of a stored version by recomputing its hash.

  Returns `:ok` or `{:error, :hash_mismatch}`.
  """
  @spec verify_integrity(version_id()) :: :ok | {:error, :not_found | :hash_mismatch}
  def verify_integrity(version_id) when is_binary(version_id) do
    case Repo.get(ObjectVersion, version_id) do
      nil ->
        {:error, :not_found}

      %ObjectVersion{content: content, content_hash: stored_hash} ->
        computed = content_hash(content)

        if :crypto.hash_equals(Base.decode16!(stored_hash, case: :lower),
                                Base.decode16!(computed, case: :lower)) do
          :ok
        else
          {:error, :hash_mismatch}
        end
    end
  end

  defp latest_record(object_key) do
    ObjectVersion
    |> where([v], v.object_key == ^object_key)
    |> order_by([v], desc: v.stored_at)
    |> limit(1)
    |> Repo.one()
  end

  defp content_hash(content) do
    :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)
  end

  defp to_metadata(record) do
    %{version_id: record.id, object_key: record.object_key,
      content_hash: record.content_hash, content_type: record.content_type,
      size_bytes: record.size_bytes, stored_at: record.stored_at, metadata: record.metadata}
  end
end
```
