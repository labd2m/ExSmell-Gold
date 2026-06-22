```elixir
defmodule Documents.VersionHistory do
  @moduledoc """
  Records an immutable revision history for documents. Every save produces
  a new `DocumentVersion` record with a content snapshot and a structured
  diff against the previous version. Diffing is performed at the field level
  so consumers can render change summaries without fetching and comparing
  full document bodies. Versions are numbered sequentially per document
  rather than using timestamps, making ordering deterministic even under
  concurrent writes (which are serialised via a database advisory lock).
  """

  alias Documents.{Document, DocumentVersion, Repo}
  alias Ecto.Multi
  alias Infrastructure.AdvisoryLock

  import Ecto.Query

  require Logger

  @type document_id :: binary()
  @type version_number :: pos_integer()

  @doc """
  Records a new version of `document` with `new_content`. Returns
  `{:ok, version}` or `{:error, reason}`. Acquires a per-document advisory
  lock to ensure version numbers are assigned without gaps or duplicates.
  """
  @spec record(Document.t(), map(), binary()) ::
          {:ok, DocumentVersion.t()} | {:error, term()}
  def record(%Document{} = document, new_content, author_id)
      when is_map(new_content) and is_binary(author_id) do
    AdvisoryLock.with_lock("doc_version:#{document.id}", fn ->
      Multi.new()
      |> Multi.run(:next_version_number, fn repo, _ ->
        number =
          DocumentVersion
          |> where([v], v.document_id == ^document.id)
          |> select([v], count(v.id))
          |> repo.one()

        {:ok, number + 1}
      end)
      |> Multi.run(:previous_content, fn repo, _ ->
        content =
          DocumentVersion
          |> where([v], v.document_id == ^document.id)
          |> order_by([v], desc: v.version_number)
          |> limit(1)
          |> select([v], v.content)
          |> repo.one()

        {:ok, content || %{}}
      end)
      |> Multi.insert(:version, fn %{next_version_number: num, previous_content: prev} ->
        diff = compute_diff(prev, new_content)

        DocumentVersion.changeset(%DocumentVersion{}, %{
          document_id: document.id,
          version_number: num,
          content: new_content,
          diff: diff,
          author_id: author_id
        })
      end)
      |> Multi.update(:document, fn %{version: version} ->
        Document.version_changeset(document, %{
          current_version: version.version_number,
          updated_at: DateTime.utc_now()
        })
      end)
      |> Repo.transaction()
      |> case do
        {:ok, %{version: version}} ->
          Logger.debug("Document version recorded",
            document_id: document.id,
            version: version.version_number,
            author_id: author_id
          )

          {:ok, version}

        {:error, _step, reason, _} ->
          {:error, reason}
      end
    end)
  end

  @doc """
  Returns all versions for `document_id`, ordered oldest first.
  """
  @spec list(document_id()) :: [DocumentVersion.t()]
  def list(document_id) when is_binary(document_id) do
    DocumentVersion
    |> where([v], v.document_id == ^document_id)
    |> order_by([v], asc: v.version_number)
    |> Repo.all()
  end

  @doc """
  Fetches a specific version by document ID and version number.
  """
  @spec fetch(document_id(), version_number()) ::
          {:ok, DocumentVersion.t()} | {:error, :not_found}
  def fetch(document_id, version_number)
      when is_binary(document_id) and is_integer(version_number) do
    case Repo.get_by(DocumentVersion,
           document_id: document_id,
           version_number: version_number
         ) do
      nil -> {:error, :not_found}
      version -> {:ok, version}
    end
  end

  @doc """
  Restores `document` to the content of `version_number`. Creates a new
  version entry so the restore itself appears in the history.
  """
  @spec restore(Document.t(), version_number(), binary()) ::
          {:ok, DocumentVersion.t()} | {:error, term()}
  def restore(%Document{} = document, version_number, author_id)
      when is_integer(version_number) and is_binary(author_id) do
    with {:ok, target_version} <- fetch(document.id, version_number) do
      record(document, target_version.content, author_id)
    end
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp compute_diff(prev, next) when is_map(prev) and is_map(next) do
    all_keys = MapSet.union(MapSet.new(Map.keys(prev)), MapSet.new(Map.keys(next)))

    Enum.reduce(all_keys, %{added: [], removed: [], changed: []}, fn key, acc ->
      case {Map.get(prev, key), Map.get(next, key)} do
        {nil, new_val} ->
          %{acc | added: [{key, new_val} | acc.added]}

        {old_val, nil} ->
          %{acc | removed: [{key, old_val} | acc.removed]}

        {old_val, new_val} when old_val != new_val ->
          %{acc | changed: [{key, old_val, new_val} | acc.changed]}

        _ ->
          acc
      end
    end)
  end
end
```
