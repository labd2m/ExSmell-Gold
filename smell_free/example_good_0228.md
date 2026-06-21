```elixir
defmodule MyApp.Documents.VersionStore do
  @moduledoc """
  A GenServer that maintains a bounded version history for collaborative
  documents. Each edit is appended as an immutable snapshot up to a
  configurable maximum depth; when the limit is reached the oldest
  version is silently evicted. Snapshots are identified by a monotonic
  version number rather than timestamps to avoid clock-skew issues in
  distributed deployments.

  The store is registered by document ID and started on demand under
  `MyApp.Documents.VersionSupervisor`.
  """

  use GenServer, restart: :transient

  @default_max_versions 50
  @idle_timeout_ms 10 * 60 * 1_000

  @type document_id :: String.t()
  @type version_number :: pos_integer()
  @type snapshot :: %{
          version: version_number(),
          content: String.t(),
          author_id: String.t(),
          saved_at: DateTime.t()
        }

  @type state :: %{
          document_id: document_id(),
          versions: [snapshot()],
          next_version: version_number(),
          max_versions: pos_integer()
        }

  @doc "Starts a version store for the given document ID."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    doc_id = Keyword.fetch!(opts, :document_id)
    GenServer.start_link(__MODULE__, opts, name: via(doc_id))
  end

  @doc "Appends a new snapshot to the document's version history."
  @spec save(document_id(), String.t(), String.t()) :: {:ok, version_number()}
  def save(document_id, content, author_id)
      when is_binary(document_id) and is_binary(content) and is_binary(author_id) do
    GenServer.call(via(document_id), {:save, content, author_id})
  end

  @doc "Returns all stored snapshots in descending version order."
  @spec history(document_id()) :: [snapshot()]
  def history(document_id) when is_binary(document_id) do
    GenServer.call(via(document_id), :history)
  end

  @doc "Fetches a specific version by number."
  @spec fetch_version(document_id(), version_number()) ::
          {:ok, snapshot()} | {:error, :not_found}
  def fetch_version(document_id, version)
      when is_binary(document_id) and is_integer(version) do
    GenServer.call(via(document_id), {:fetch_version, version})
  end

  @impl GenServer
  def init(opts) do
    max = Keyword.get(opts, :max_versions, @default_max_versions)

    state = %{
      document_id: Keyword.fetch!(opts, :document_id),
      versions: [],
      next_version: 1,
      max_versions: max
    }

    {:ok, state, @idle_timeout_ms}
  end

  @impl GenServer
  def handle_call({:save, content, author_id}, _from, state) do
    snapshot = %{
      version: state.next_version,
      content: content,
      author_id: author_id,
      saved_at: DateTime.utc_now()
    }

    updated_versions =
      [snapshot | state.versions]
      |> Enum.take(state.max_versions)

    new_state = %{state | versions: updated_versions, next_version: state.next_version + 1}
    {:reply, {:ok, snapshot.version}, new_state, @idle_timeout_ms}
  end

  @impl GenServer
  def handle_call(:history, _from, state) do
    {:reply, state.versions, state, @idle_timeout_ms}
  end

  @impl GenServer
  def handle_call({:fetch_version, version}, _from, state) do
    result =
      Enum.find(state.versions, fn s -> s.version == version end)
      |> case do
        nil -> {:error, :not_found}
        snapshot -> {:ok, snapshot}
      end

    {:reply, result, state, @idle_timeout_ms}
  end

  @impl GenServer
  def handle_info(:timeout, state) do
    {:stop, :normal, state}
  end

  @spec via(document_id()) :: {:via, Registry, {MyApp.Documents.VersionRegistry, document_id()}}
  defp via(doc_id), do: {:via, Registry, {MyApp.Documents.VersionRegistry, doc_id}}
end
```
