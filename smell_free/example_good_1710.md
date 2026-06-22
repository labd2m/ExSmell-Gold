```elixir
defmodule Documents.VersionStore do
  @moduledoc """
  Immutable version store for document content snapshots.
  Each save produces a new version; previous versions are retained and retrievable by number.
  """

  use GenServer

  @type document_id :: String.t()
  @type version_number :: pos_integer()
  @type snapshot :: %{version: version_number(), content: String.t(), saved_at: DateTime.t(), author_id: String.t()}
  @type state :: %{versions: %{document_id() => [snapshot()]}}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, %{versions: %{}}, name: Keyword.get(opts, :name, __MODULE__))
  end

  @spec save(document_id(), String.t(), String.t()) :: {:ok, snapshot()}
  def save(document_id, content, author_id)
      when is_binary(document_id) and is_binary(content) and is_binary(author_id) do
    GenServer.call(__MODULE__, {:save, document_id, content, author_id})
  end

  @spec fetch(document_id(), version_number()) :: {:ok, snapshot()} | {:error, :not_found}
  def fetch(document_id, version) when is_binary(document_id) and is_integer(version) and version > 0 do
    GenServer.call(__MODULE__, {:fetch, document_id, version})
  end

  @spec latest(document_id()) :: {:ok, snapshot()} | {:error, :no_versions}
  def latest(document_id) when is_binary(document_id) do
    GenServer.call(__MODULE__, {:latest, document_id})
  end

  @spec history(document_id()) :: [snapshot()]
  def history(document_id) when is_binary(document_id) do
    GenServer.call(__MODULE__, {:history, document_id})
  end

  @spec diff_versions(document_id(), version_number(), version_number()) ::
          {:ok, %{added: non_neg_integer(), removed: non_neg_integer()}} | {:error, :not_found}
  def diff_versions(document_id, version_a, version_b) do
    with {:ok, snap_a} <- fetch(document_id, version_a),
         {:ok, snap_b} <- fetch(document_id, version_b) do
      {:ok, compute_line_diff(snap_a.content, snap_b.content)}
    end
  end

  @impl GenServer
  def init(state), do: {:ok, state}

  @impl GenServer
  def handle_call({:save, doc_id, content, author_id}, _from, state) do
    existing = Map.get(state.versions, doc_id, [])
    version_number = length(existing) + 1
    snapshot = %{version: version_number, content: content, saved_at: DateTime.utc_now(), author_id: author_id}
    new_state = %{state | versions: Map.put(state.versions, doc_id, existing ++ [snapshot])}
    {:reply, {:ok, snapshot}, new_state}
  end

  def handle_call({:fetch, doc_id, version}, _from, state) do
    result =
      state.versions
      |> Map.get(doc_id, [])
      |> Enum.find(&(&1.version == version))
      |> wrap_result()

    {:reply, result, state}
  end

  def handle_call({:latest, doc_id}, _from, state) do
    result =
      case Map.get(state.versions, doc_id, []) do
        [] -> {:error, :no_versions}
        versions -> {:ok, List.last(versions)}
      end

    {:reply, result, state}
  end

  def handle_call({:history, doc_id}, _from, state) do
    {:reply, Map.get(state.versions, doc_id, []), state}
  end

  @spec wrap_result(snapshot() | nil) :: {:ok, snapshot()} | {:error, :not_found}
  defp wrap_result(nil), do: {:error, :not_found}
  defp wrap_result(snapshot), do: {:ok, snapshot}

  @spec compute_line_diff(String.t(), String.t()) :: %{added: non_neg_integer(), removed: non_neg_integer()}
  defp compute_line_diff(content_a, content_b) do
    lines_a = MapSet.new(String.split(content_a, "\n"))
    lines_b = MapSet.new(String.split(content_b, "\n"))

    %{
      added: MapSet.difference(lines_b, lines_a) |> MapSet.size(),
      removed: MapSet.difference(lines_a, lines_b) |> MapSet.size()
    }
  end
end
```
