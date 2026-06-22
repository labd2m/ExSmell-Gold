```elixir
defmodule MyApp.Documents.CollaborativeEditor do
  @moduledoc """
  A GenServer representing a single collaboratively edited document
  session. Edits are applied as operational transforms: each operation
  carries a revision number and is rebased against concurrent operations
  before being applied, preserving convergence across clients.

  The server holds the authoritative document state and broadcasts
  acknowledged operations over PubSub so all connected clients can
  update their local replicas.
  """

  use GenServer, restart: :transient

  require Logger

  alias MyApp.Documents.OTEngine

  @pubsub MyApp.PubSub
  @idle_timeout_ms 20 * 60 * 1_000
  @max_history 500

  @type doc_id :: String.t()
  @type operation :: map()
  @type client_id :: String.t()

  @doc "Starts an editor session for `doc_id`."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    doc_id = Keyword.fetch!(opts, :doc_id)
    GenServer.start_link(__MODULE__, opts, name: via(doc_id))
  end

  @doc "Returns the current document content and revision."
  @spec snapshot(doc_id()) :: {:ok, %{content: String.t(), revision: non_neg_integer()}}
  def snapshot(doc_id) when is_binary(doc_id) do
    GenServer.call(via(doc_id), :snapshot)
  end

  @doc """
  Submits an `operation` from `client_id` at `client_revision`. The
  server transforms the operation against any concurrent operations and
  broadcasts the result to all subscribers.
  """
  @spec submit(doc_id(), client_id(), operation(), non_neg_integer()) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def submit(doc_id, client_id, operation, client_revision)
      when is_binary(doc_id) and is_binary(client_id) and is_integer(client_revision) do
    GenServer.call(via(doc_id), {:submit, client_id, operation, client_revision})
  end

  @doc "Subscribes the calling process to operations broadcast on this document."
  @spec subscribe(doc_id()) :: :ok | {:error, term()}
  def subscribe(doc_id), do: Phoenix.PubSub.subscribe(@pubsub, topic(doc_id))

  @impl GenServer
  def init(opts) do
    doc_id = Keyword.fetch!(opts, :doc_id)
    initial_content = Keyword.get(opts, :content, "")

    state = %{
      doc_id: doc_id,
      content: initial_content,
      revision: 0,
      history: []
    }

    {:ok, state, @idle_timeout_ms}
  end

  @impl GenServer
  def handle_call(:snapshot, _from, state) do
    {:reply, {:ok, %{content: state.content, revision: state.revision}}, state, @idle_timeout_ms}
  end

  @impl GenServer
  def handle_call({:submit, client_id, operation, client_revision}, _from, state) do
    concurrent_ops = operations_since(state.history, client_revision)

    case OTEngine.transform(operation, concurrent_ops) do
      {:ok, transformed_op} ->
        {:ok, new_content} = OTEngine.apply(state.content, transformed_op)
        new_revision = state.revision + 1

        history_entry = %{
          revision: new_revision,
          client_id: client_id,
          operation: transformed_op
        }

        new_history =
          [history_entry | state.history]
          |> Enum.take(@max_history)

        new_state = %{state | content: new_content, revision: new_revision, history: new_history}

        Phoenix.PubSub.broadcast(@pubsub, topic(state.doc_id), {:operation_applied, %{
          revision: new_revision,
          client_id: client_id,
          operation: transformed_op
        }})

        {:reply, {:ok, new_revision}, new_state, @idle_timeout_ms}

      {:error, reason} ->
        {:reply, {:error, reason}, state, @idle_timeout_ms}
    end
  end

  @impl GenServer
  def handle_info(:timeout, state) do
    Logger.info("collaborative_editor_idle_exit", doc_id: state.doc_id)
    {:stop, :normal, state}
  end

  @spec operations_since([map()], non_neg_integer()) :: [operation()]
  defp operations_since(history, since_revision) do
    history
    |> Enum.filter(fn entry -> entry.revision > since_revision end)
    |> Enum.sort_by(& &1.revision)
    |> Enum.map(& &1.operation)
  end

  @spec topic(doc_id()) :: String.t()
  defp topic(doc_id), do: "editor:#{doc_id}"

  @spec via(doc_id()) :: {:via, Registry, {MyApp.Documents.EditorRegistry, doc_id()}}
  defp via(doc_id), do: {:via, Registry, {MyApp.Documents.EditorRegistry, doc_id}}
end
```
