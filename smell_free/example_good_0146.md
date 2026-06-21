```elixir
defmodule Documents.VersionStore do
  @moduledoc """
  Persists immutable document versions and surfaces the current revision.
  Each write creates a new version record; no existing row is ever mutated.
  Callers retrieve the full version history or diff two specific revisions.
  """

  import Ecto.Query, warn: false

  alias MyApp.Repo
  alias Documents.Version

  @type document_id :: String.t()
  @type version_number :: pos_integer()
  @type content :: String.t()

  @doc """
  Stores a new version of `document_id` with the given content.
  The version number is derived from the current maximum plus one.
  """
  @spec commit(document_id(), content(), String.t()) ::
          {:ok, Version.t()} | {:error, Ecto.Changeset.t()}
  def commit(document_id, content, author_id)
      when is_binary(document_id) and is_binary(content) and is_binary(author_id) do
    next_version = next_version_number(document_id)

    %Version{}
    |> Version.changeset(%{
      document_id: document_id,
      content: content,
      author_id: author_id,
      version: next_version
    })
    |> Repo.insert()
  end

  @doc "Returns the latest version of a document, or `{:error, :not_found}`."
  @spec fetch_current(document_id()) :: {:ok, Version.t()} | {:error, :not_found}
  def fetch_current(document_id) when is_binary(document_id) do
    query =
      from v in Version,
        where: v.document_id == ^document_id,
        order_by: [desc: v.version],
        limit: 1

    case Repo.one(query) do
      nil -> {:error, :not_found}
      version -> {:ok, version}
    end
  end

  @doc "Fetches a specific version number of a document."
  @spec fetch_version(document_id(), version_number()) ::
          {:ok, Version.t()} | {:error, :not_found}
  def fetch_version(document_id, number)
      when is_binary(document_id) and is_integer(number) and number > 0 do
    query =
      from v in Version,
        where: v.document_id == ^document_id and v.version == ^number

    case Repo.one(query) do
      nil -> {:error, :not_found}
      version -> {:ok, version}
    end
  end

  @doc "Returns all versions for a document sorted oldest-first."
  @spec history(document_id()) :: [Version.t()]
  def history(document_id) when is_binary(document_id) do
    Version
    |> where([v], v.document_id == ^document_id)
    |> order_by([v], asc: v.version)
    |> Repo.all()
  end

  @doc """
  Produces a simple line-level diff between two specific versions.
  Returns `{:error, :not_found}` when either version is absent.
  """
  @spec diff(document_id(), version_number(), version_number()) ::
          {:ok, [String.t()]} | {:error, :not_found}
  def diff(document_id, from_version, to_version) do
    with {:ok, v_from} <- fetch_version(document_id, from_version),
         {:ok, v_to} <- fetch_version(document_id, to_version) do
      {:ok, compute_diff(v_from.content, v_to.content)}
    end
  end

  defp next_version_number(document_id) do
    query =
      from v in Version,
        where: v.document_id == ^document_id,
        select: max(v.version)

    (Repo.one(query) || 0) + 1
  end

  defp compute_diff(old_content, new_content) do
    old_lines = String.split(old_content, "\n")
    new_lines = String.split(new_content, "\n")

    removed = Enum.reject(old_lines, &(&1 in new_lines)) |> Enum.map(&"- #{&1}")
    added = Enum.reject(new_lines, &(&1 in old_lines)) |> Enum.map(&"+ #{&1}")
    removed ++ added
  end
end
```
