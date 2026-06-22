```elixir
defmodule Docs.VersionedStore do
  @moduledoc """
  Context for managing versioned document content with change tracking.

  Every save produces a new immutable version. The current head and full
  version history are queryable. Diffs between versions are computed on demand.
  """

  import Ecto.Query

  alias Docs.Repo
  alias Docs.VersionedStore.{Document, Version, Differ}

  @type result(t) :: {:ok, t} | {:error, Ecto.Changeset.t() | String.t()}

  @doc """
  Creates a new document with an initial version.
  """
  @spec create(String.t(), String.t(), String.t()) :: result(%{document: Document.t(), version: Version.t()})
  def create(title, content, author_id)
      when is_binary(title) and is_binary(content) and is_binary(author_id) do
    Repo.transaction(fn ->
      with {:ok, doc} <- insert_document(title, author_id),
           {:ok, ver} <- insert_version(doc.id, content, author_id, 1) do
        %{document: doc, version: ver}
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  @doc """
  Saves a new version of an existing document.
  """
  @spec save(String.t(), String.t(), String.t()) :: result(Version.t())
  def save(document_id, content, author_id)
      when is_binary(document_id) and is_binary(content) and is_binary(author_id) do
    Repo.transaction(fn ->
      with {:ok, doc} <- fetch_document(document_id),
           next_number = next_version_number(document_id),
           {:ok, ver} <- insert_version(doc.id, content, author_id, next_number) do
        ver
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  @doc """
  Returns the latest version content for a document.
  """
  @spec head(String.t()) :: {:ok, Version.t()} | {:error, String.t()}
  def head(document_id) when is_binary(document_id) do
    Version
    |> where([v], v.document_id == ^document_id)
    |> order_by([v], desc: v.number)
    |> limit(1)
    |> Repo.one()
    |> case do
      nil -> {:error, "document not found or has no versions"}
      ver -> {:ok, ver}
    end
  end

  @doc """
  Returns the version at the given version number.
  """
  @spec at_version(String.t(), pos_integer()) :: {:ok, Version.t()} | {:error, String.t()}
  def at_version(document_id, number) when is_binary(document_id) and is_integer(number) do
    Version
    |> where([v], v.document_id == ^document_id and v.number == ^number)
    |> Repo.one()
    |> case do
      nil -> {:error, "version #{number} not found"}
      ver -> {:ok, ver}
    end
  end

  @doc """
  Returns the full list of versions for a document, oldest first.
  """
  @spec history(String.t()) :: [Version.t()]
  def history(document_id) when is_binary(document_id) do
    Version
    |> where([v], v.document_id == ^document_id)
    |> order_by([v], asc: v.number)
    |> Repo.all()
  end

  @doc """
  Returns a line-level diff between two version numbers.
  """
  @spec diff(String.t(), pos_integer(), pos_integer()) :: {:ok, [map()]} | {:error, String.t()}
  def diff(document_id, from_number, to_number)
      when is_binary(document_id) and is_integer(from_number) and is_integer(to_number) do
    with {:ok, from_ver} <- at_version(document_id, from_number),
         {:ok, to_ver} <- at_version(document_id, to_number) do
      {:ok, Differ.line_diff(from_ver.content, to_ver.content)}
    end
  end

  # --- private helpers ---

  defp insert_document(title, author_id) do
    %Document{}
    |> Document.changeset(%{title: title, author_id: author_id})
    |> Repo.insert()
  end

  defp insert_version(document_id, content, author_id, number) do
    %Version{}
    |> Version.changeset(%{
      document_id: document_id,
      content: content,
      author_id: author_id,
      number: number
    })
    |> Repo.insert()
  end

  defp fetch_document(id) do
    case Repo.get(Document, id) do
      nil -> {:error, "document not found"}
      doc -> {:ok, doc}
    end
  end

  defp next_version_number(document_id) do
    Version
    |> where([v], v.document_id == ^document_id)
    |> Repo.aggregate(:max, :number)
    |> then(&((&1 || 0) + 1))
  end
end

defmodule Docs.VersionedStore.Differ do
  @moduledoc "Computes line-level diffs between two content strings."

  @spec line_diff(String.t(), String.t()) :: [map()]
  def line_diff(from_content, to_content)
      when is_binary(from_content) and is_binary(to_content) do
    from_lines = String.split(from_content, "\n")
    to_lines = String.split(to_content, "\n")

    removed = MapSet.difference(MapSet.new(from_lines), MapSet.new(to_lines))
    added = MapSet.difference(MapSet.new(to_lines), MapSet.new(from_lines))

    removals = Enum.map(removed, &%{op: :remove, line: &1})
    additions = Enum.map(added, &%{op: :add, line: &1})

    removals ++ additions
  end
end
```
