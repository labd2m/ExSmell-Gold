```elixir
defmodule Documents.VersionStore do
  @moduledoc """
  Maintains an append-only version history for document content.
  Provides diff-capable retrieval, restoration, and pruning of old revisions.
  """

  alias Documents.{Repo, DocumentVersion, Document}
  import Ecto.Query

  @type document_id :: String.t()
  @type version_number :: pos_integer()

  @spec commit(Document.t(), String.t(), String.t()) ::
          {:ok, DocumentVersion.t()} | {:error, Ecto.Changeset.t()}
  def commit(%Document{} = doc, content, author_id) when is_binary(content) do
    next_version = next_version_number(doc.id)

    %DocumentVersion{}
    |> DocumentVersion.creation_changeset(%{
      document_id: doc.id,
      content: content,
      author_id: author_id,
      version_number: next_version,
      byte_size: byte_size(content)
    })
    |> Repo.insert()
  end

  @spec fetch_version(document_id(), version_number()) ::
          {:ok, DocumentVersion.t()} | {:error, :not_found}
  def fetch_version(document_id, version_number)
      when is_binary(document_id) and is_integer(version_number) do
    case Repo.get_by(DocumentVersion,
           document_id: document_id,
           version_number: version_number
         ) do
      nil -> {:error, :not_found}
      version -> {:ok, version}
    end
  end

  @spec list_versions(document_id()) :: [DocumentVersion.t()]
  def list_versions(document_id) when is_binary(document_id) do
    from(v in DocumentVersion,
      where: v.document_id == ^document_id,
      order_by: [desc: v.version_number],
      select: %{
        version_number: v.version_number,
        author_id: v.author_id,
        byte_size: v.byte_size,
        inserted_at: v.inserted_at
      }
    )
    |> Repo.all()
  end

  @spec restore(Document.t(), version_number(), String.t()) ::
          {:ok, DocumentVersion.t()} | {:error, :not_found | Ecto.Changeset.t()}
  def restore(%Document{} = doc, version_number, restored_by) do
    with {:ok, target} <- fetch_version(doc.id, version_number) do
      commit(doc, target.content, restored_by)
    end
  end

  @spec prune_old_versions(document_id(), pos_integer()) :: {:ok, non_neg_integer()}
  def prune_old_versions(document_id, keep_latest) when keep_latest > 0 do
    cutoff_query =
      from(v in DocumentVersion,
        where: v.document_id == ^document_id,
        order_by: [desc: v.version_number],
        offset: ^keep_latest,
        select: v.id
      )

    {deleted, _} =
      from(v in DocumentVersion, where: v.id in subquery(cutoff_query))
      |> Repo.delete_all()

    {:ok, deleted}
  end

  @spec next_version_number(document_id()) :: version_number()
  defp next_version_number(document_id) do
    from(v in DocumentVersion,
      where: v.document_id == ^document_id,
      select: coalesce(max(v.version_number), 0)
    )
    |> Repo.one()
    |> Kernel.+(1)
  end
end
```
