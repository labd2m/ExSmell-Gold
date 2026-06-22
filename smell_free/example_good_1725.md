```elixir
defmodule Documents.VersionManager do
  @moduledoc """
  Manages versioned snapshots of mutable documents.

  Each time a document is updated, a new immutable version record is
  created and linked to the document. The manager provides access to
  the full version history and supports restoring a document to any
  prior snapshot.
  """

  alias Documents.Repo
  alias Documents.Document
  alias Documents.DocumentVersion

  import Ecto.Query, warn: false

  @type document_id :: Ecto.UUID.t()

  @doc """
  Creates a new version snapshot of the given document.

  The snapshot captures the current content and metadata, incrementing
  the version number atomically within a transaction.
  """
  @spec snapshot(Document.t()) ::
          {:ok, DocumentVersion.t()} | {:error, :snapshot_failed}
  def snapshot(%Document{} = document) do
    Repo.transaction(fn ->
      next_version = current_version_number(document.id) + 1

      attrs = %{
        document_id: document.id,
        version_number: next_version,
        title: document.title,
        body: document.body,
        authored_by: document.last_edited_by,
        snapshotted_at: DateTime.utc_now()
      }

      case Repo.insert(DocumentVersion.changeset(%DocumentVersion{}, attrs)) do
        {:ok, version} -> version
        {:error, _} -> Repo.rollback(:snapshot_failed)
      end
    end)
    |> normalize_result(:snapshot_failed)
  end

  @doc """
  Returns the ordered version history for a document, newest first.
  """
  @spec history(document_id()) :: [DocumentVersion.t()]
  def history(document_id) when is_binary(document_id) do
    DocumentVersion
    |> where([v], v.document_id == ^document_id)
    |> order_by([v], desc: v.version_number)
    |> Repo.all()
  end

  @doc """
  Fetches a specific version of a document by version number.
  """
  @spec fetch_version(document_id(), pos_integer()) ::
          {:ok, DocumentVersion.t()} | {:error, :not_found}
  def fetch_version(document_id, version_number)
      when is_binary(document_id) and is_integer(version_number) and version_number > 0 do
    case Repo.get_by(DocumentVersion,
           document_id: document_id,
           version_number: version_number
         ) do
      nil -> {:error, :not_found}
      version -> {:ok, version}
    end
  end

  @doc """
  Restores a document to the state captured in the given version.

  Creates a new version snapshot reflecting the restoration, so the
  history remains a complete forward-only log.
  """
  @spec restore(Document.t(), DocumentVersion.t()) ::
          {:ok, Document.t()} | {:error, :restore_failed}
  def restore(%Document{} = document, %DocumentVersion{} = version) do
    Repo.transaction(fn ->
      restored_attrs = %{
        title: version.title,
        body: version.body,
        last_edited_by: document.last_edited_by,
        restored_from_version: version.version_number
      }

      with {:ok, updated_doc} <- update_document(document, restored_attrs),
           {:ok, _snapshot} <- snapshot(updated_doc) do
        updated_doc
      else
        {:error, _} -> Repo.rollback(:restore_failed)
      end
    end)
    |> normalize_result(:restore_failed)
  end

  @spec current_version_number(document_id()) :: non_neg_integer()
  defp current_version_number(document_id) do
    DocumentVersion
    |> where([v], v.document_id == ^document_id)
    |> Repo.aggregate(:max, :version_number) || 0
  end

  @spec update_document(Document.t(), map()) ::
          {:ok, Document.t()} | {:error, Ecto.Changeset.t()}
  defp update_document(document, attrs) do
    document
    |> Document.update_changeset(attrs)
    |> Repo.update()
  end

  @spec normalize_result({:ok, term()} | {:error, term()}, atom()) ::
          {:ok, term()} | {:error, atom()}
  defp normalize_result({:ok, value}, _), do: {:ok, value}
  defp normalize_result({:error, _}, fallback_reason), do: {:error, fallback_reason}
end
```
