```elixir
defmodule Versioning.Snapshot do
  @moduledoc """
  An immutable point-in-time snapshot of a versioned document.
  Snapshots are stored by version number and form an append-only history.
  """

  @enforce_keys [:id, :document_id, :version, :content, :author_id, :captured_at]
  defstruct [:id, :document_id, :version, :content, :author_id, :captured_at, :change_summary]

  @type t :: %__MODULE__{
          id: String.t(),
          document_id: String.t(),
          version: pos_integer(),
          content: String.t(),
          author_id: integer(),
          captured_at: DateTime.t(),
          change_summary: String.t() | nil
        }

  @spec new(String.t(), pos_integer(), String.t(), integer(), keyword()) :: t()
  def new(document_id, version, content, author_id, opts \\ [])
      when is_binary(document_id) and is_integer(version) and version > 0 and
             is_binary(content) and is_integer(author_id) do
    %__MODULE__{
      id: generate_id(),
      document_id: document_id,
      version: version,
      content: content,
      author_id: author_id,
      captured_at: DateTime.utc_now(),
      change_summary: Keyword.get(opts, :change_summary)
    }
  end

  defp generate_id do
    :crypto.strong_rand_bytes(10) |> Base.url_encode64(padding: false)
  end
end

defmodule Versioning.Differ do
  @moduledoc """
  Computes a structured textual diff between two snapshot versions.
  The diff is represented as a list of change hunks, each annotated
  with its operation type and line range.
  """

  alias Versioning.Snapshot

  @type operation :: :added | :removed | :unchanged
  @type hunk :: %{operation: operation(), lines: list(String.t()), line_start: pos_integer()}
  @type diff :: %{from_version: pos_integer(), to_version: pos_integer(), hunks: list(hunk())}

  @spec diff(Snapshot.t(), Snapshot.t()) :: {:ok, diff()} | {:error, :incompatible_documents}
  def diff(%Snapshot{document_id: doc_a} = from, %Snapshot{document_id: doc_b} = to)
      when doc_a != doc_b do
    _ = {from, to}
    {:error, :incompatible_documents}
  end

  def diff(%Snapshot{} = from, %Snapshot{} = to) do
    hunks = compute_hunks(split_lines(from.content), split_lines(to.content))
    {:ok, %{from_version: from.version, to_version: to.version, hunks: hunks}}
  end

  @spec summary(diff()) :: %{added: non_neg_integer(), removed: non_neg_integer()}
  def summary(%{hunks: hunks}) do
    Enum.reduce(hunks, %{added: 0, removed: 0}, fn hunk, acc ->
      count = length(hunk.lines)
      case hunk.operation do
        :added -> Map.update!(acc, :added, &(&1 + count))
        :removed -> Map.update!(acc, :removed, &(&1 + count))
        :unchanged -> acc
      end
    end)
  end

  defp split_lines(text), do: String.split(text, "\n")

  defp compute_hunks(from_lines, to_lines) do
    removed = MapSet.new(from_lines) |> MapSet.difference(MapSet.new(to_lines))
    added = MapSet.new(to_lines) |> MapSet.difference(MapSet.new(from_lines))

    removed_hunks =
      from_lines
      |> Enum.with_index(1)
      |> Enum.filter(fn {line, _} -> MapSet.member?(removed, line) end)
      |> Enum.map(fn {line, idx} -> %{operation: :removed, lines: [line], line_start: idx} end)

    added_hunks =
      to_lines
      |> Enum.with_index(1)
      |> Enum.filter(fn {line, _} -> MapSet.member?(added, line) end)
      |> Enum.map(fn {line, idx} -> %{operation: :added, lines: [line], line_start: idx} end)

    (removed_hunks ++ added_hunks) |> Enum.sort_by(& &1.line_start)
  end
end

defmodule Versioning.History do
  @moduledoc """
  In-memory version history for a single document. Snapshots are stored in
  ascending version order and queried by version number or recency.
  """

  alias Versioning.Snapshot

  @type t :: %__MODULE__{document_id: String.t(), snapshots: %{pos_integer() => Snapshot.t()}}

  defstruct [:document_id, snapshots: %{}]

  @spec new(String.t()) :: t()
  def new(document_id) when is_binary(document_id) do
    %__MODULE__{document_id: document_id}
  end

  @spec push(t(), Snapshot.t()) :: {:ok, t()} | {:error, atom()}
  def push(%__MODULE__{document_id: doc_id} = history, %Snapshot{document_id: doc_id} = snap) do
    if Map.has_key?(history.snapshots, snap.version) do
      {:error, :version_already_exists}
    else
      {:ok, %{history | snapshots: Map.put(history.snapshots, snap.version, snap)}}
    end
  end

  def push(%__MODULE__{}, %Snapshot{}), do: {:error, :document_mismatch}

  @spec at_version(t(), pos_integer()) :: {:ok, Snapshot.t()} | {:error, :not_found}
  def at_version(%__MODULE__{snapshots: snaps}, version) when is_integer(version) do
    case Map.fetch(snaps, version) do
      {:ok, snap} -> {:ok, snap}
      :error -> {:error, :not_found}
    end
  end

  @spec latest(t()) :: {:ok, Snapshot.t()} | {:error, :no_snapshots}
  def latest(%__MODULE__{snapshots: snaps}) when map_size(snaps) == 0, do: {:error, :no_snapshots}

  def latest(%__MODULE__{snapshots: snaps}) do
    snap = snaps |> Map.values() |> Enum.max_by(& &1.version)
    {:ok, snap}
  end

  @spec all_versions(t()) :: list(pos_integer())
  def all_versions(%__MODULE__{snapshots: snaps}) do
    snaps |> Map.keys() |> Enum.sort()
  end
end
```
