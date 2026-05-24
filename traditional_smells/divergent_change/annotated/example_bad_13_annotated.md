# Annotated Example — Divergent Change

| Field | Value |
|---|---|
| **Smell name** | Divergent Change |
| **Expected smell location** | `DocumentVault` module |
| **Affected functions** | `upload_document/2`, `delete_document/2`, `get_document/2` (storage reason) and `create_version/2`, `restore_version/2`, `list_versions/1` (versioning reason) and `grant_access/3`, `revoke_access/3`, `can_access?/3` (access control reason) |
| **Explanation** | The module conflates document storage, version history management, and fine-grained access control — three independent document management concerns. A change to the storage backend, the versioning strategy, or the access permission model would each independently require modifications to this module. |

```elixir
defmodule Docs.DocumentVault do
  @moduledoc """
  Manages document storage, versioning, and access control.
  """

  alias Docs.Repo
  alias Docs.Documents.Document
  alias Docs.Documents.Version
  alias Docs.Access.DocumentGrant

  import Ecto.Query
  require Logger

  # VALIDATION: SMELL START - Divergent Change
  # VALIDATION: This is a smell because the module has three independent reasons
  # to change: (1) storage backend or file organisation rules, (2) versioning
  # semantics (e.g. adding branching or compression), and (3) access control
  # model (e.g. switching from per-user grants to role-based ACLs). Each
  # concern is unrelated to the others.

  ## ── Storage ──────────────────────────────────────────────────────────────────

  @doc "Uploads a new document and stores metadata in the database."
  @spec upload_document(String.t(), map()) :: {:ok, Document.t()} | {:error, term()}
  def upload_document(owner_id, %{filename: filename, content: content, mime_type: mime}) do
    storage_key = generate_storage_key(owner_id, filename)

    with :ok <- Docs.Storage.put(storage_key, content, content_type: mime) do
      attrs = %{
        owner_id: owner_id,
        filename: filename,
        mime_type: mime,
        storage_key: storage_key,
        size_bytes: byte_size(content),
        status: :active,
        uploaded_at: DateTime.utc_now()
      }

      case Repo.insert(Document.changeset(%Document{}, attrs)) do
        {:ok, doc} ->
          create_version(doc, %{content: content, label: "v1"})
          {:ok, doc}

        error ->
          Docs.Storage.delete(storage_key)
          error
      end
    end
  end

  @doc "Permanently deletes a document and all of its versions."
  @spec delete_document(Document.t(), String.t()) :: :ok | {:error, atom()}
  def delete_document(%Document{} = document, requester_id) do
    if document.owner_id == requester_id do
      Repo.transaction(fn ->
        Version |> where([v], v.document_id == ^document.id) |> Repo.delete_all()
        DocumentGrant |> where([g], g.document_id == ^document.id) |> Repo.delete_all()
        Repo.delete!(document)
        Docs.Storage.delete(document.storage_key)
        Logger.info("Document #{document.id} deleted by #{requester_id}")
      end)

      :ok
    else
      {:error, :unauthorized}
    end
  end

  @doc "Retrieves a document, checking that the requester has at least read access."
  @spec get_document(String.t(), String.t()) :: {:ok, Document.t()} | {:error, atom()}
  def get_document(document_id, requester_id) do
    document = Repo.get!(Document, document_id)

    if can_access?(document, requester_id, :read) do
      {:ok, document}
    else
      {:error, :forbidden}
    end
  end

  ## ── Versioning ───────────────────────────────────────────────────────────────

  @doc "Creates a new version snapshot of a document."
  @spec create_version(Document.t(), map()) :: {:ok, Version.t()} | {:error, term()}
  def create_version(%Document{id: doc_id} = document, %{content: content} = opts) do
    next_num = next_version_number(doc_id)
    version_key = "#{document.storage_key}/v#{next_num}"

    with :ok <- Docs.Storage.put(version_key, content) do
      attrs = %{
        document_id: doc_id,
        version_number: next_num,
        storage_key: version_key,
        size_bytes: byte_size(content),
        label: opts[:label] || "v#{next_num}",
        created_at: DateTime.utc_now()
      }

      %Version{} |> Version.changeset(attrs) |> Repo.insert()
    end
  end

  @doc "Restores a document to a specific historical version."
  @spec restore_version(Document.t(), Version.t()) :: {:ok, Document.t()} | {:error, term()}
  def restore_version(%Document{} = document, %Version{storage_key: version_key}) do
    with {:ok, content} <- Docs.Storage.get(version_key),
         :ok <- Docs.Storage.put(document.storage_key, content) do
      document
      |> Document.changeset(%{size_bytes: byte_size(content), updated_at: DateTime.utc_now()})
      |> Repo.update()
    end
  end

  @doc "Lists all stored versions of a document, newest first."
  @spec list_versions(Document.t()) :: [Version.t()]
  def list_versions(%Document{id: doc_id}) do
    Version
    |> where([v], v.document_id == ^doc_id)
    |> order_by([v], desc: v.version_number)
    |> Repo.all()
  end

  ## ── Access Control ───────────────────────────────────────────────────────────

  @doc "Grants a specific permission level to a user on a document."
  @spec grant_access(Document.t(), String.t(), atom()) ::
          {:ok, DocumentGrant.t()} | {:error, term()}
  def grant_access(%Document{id: doc_id}, user_id, permission)
      when permission in [:read, :write, :admin] do
    attrs = %{
      document_id: doc_id,
      user_id: user_id,
      permission: permission,
      granted_at: DateTime.utc_now()
    }

    %DocumentGrant{}
    |> DocumentGrant.changeset(attrs)
    |> Repo.insert(
      on_conflict: [set: [permission: permission]],
      conflict_target: [:document_id, :user_id]
    )
  end

  @doc "Revokes all access grants for a user on a document."
  @spec revoke_access(Document.t(), String.t(), atom()) :: :ok
  def revoke_access(%Document{id: doc_id}, user_id, :all) do
    DocumentGrant
    |> where([g], g.document_id == ^doc_id and g.user_id == ^user_id)
    |> Repo.delete_all()

    :ok
  end

  def revoke_access(%Document{id: doc_id}, user_id, permission) do
    DocumentGrant
    |> where(
      [g],
      g.document_id == ^doc_id and g.user_id == ^user_id and g.permission == ^permission
    )
    |> Repo.delete_all()

    :ok
  end

  @doc "Returns true if the given user holds the required permission on the document."
  @spec can_access?(Document.t(), String.t(), atom()) :: boolean()
  def can_access?(%Document{owner_id: owner_id}, user_id, _permission)
      when owner_id == user_id,
      do: true

  def can_access?(%Document{id: doc_id}, user_id, required_permission) do
    permission_rank = %{read: 1, write: 2, admin: 3}
    required_rank = Map.fetch!(permission_rank, required_permission)

    DocumentGrant
    |> where([g], g.document_id == ^doc_id and g.user_id == ^user_id)
    |> select([g], g.permission)
    |> Repo.all()
    |> Enum.any?(fn p -> Map.get(permission_rank, p, 0) >= required_rank end)
  end

  ## ── Private Helpers ──────────────────────────────────────────────────────────

  defp generate_storage_key(owner_id, filename) do
    hash = :crypto.hash(:sha256, "#{owner_id}-#{filename}-#{System.system_time()}") |> Base.encode16(case: :lower)
    "documents/#{owner_id}/#{hash}/#{filename}"
  end

  defp next_version_number(document_id) do
    current =
      Version
      |> where([v], v.document_id == ^document_id)
      |> select([v], max(v.version_number))
      |> Repo.one()

    (current || 0) + 1
  end

  # VALIDATION: SMELL END
end
```
