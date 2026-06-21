```elixir
defmodule Collab.DocumentSession do
  @moduledoc """
  A GenServer that manages the shared editing state for a single collaborative
  document session. Multiple LiveView processes connect to this session server,
  submit operations, and receive the merged result. Operations are merged using
  an Operational Transformation (OT) approach: each operation carries a
  revision number, and the server transforms concurrent operations against
  each other before applying them to the canonical document state.
  The session is started on-demand via `DynamicSupervisor` and idles itself
  out after a configurable period of inactivity.
  """

  use GenServer

  alias Collab.{Operation, OperationTransformer}

  require Logger

  @idle_timeout_ms 30 * 60 * 1000

  @type session_id :: binary()
  @type subscriber :: pid()

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    session_id = Keyword.fetch!(opts, :session_id)
    GenServer.start_link(__MODULE__, opts, name: via(session_id))
  end

  @doc """
  Subscribes the calling process to operation broadcasts for `session_id`.
  Returns `{:ok, %{document: content, revision: integer}}` with the current
  document state so the subscriber can initialise its local copy.
  """
  @spec join(session_id()) :: {:ok, map()} | {:error, term()}
  def join(session_id) when is_binary(session_id) do
    GenServer.call(via(session_id), {:join, self()})
  end

  @doc """
  Submits an operation from a subscriber. The operation is transformed against
  any concurrent operations, applied to the document, and broadcast to all
  other subscribers. Returns `{:ok, revision}` or `{:error, reason}`.
  """
  @spec submit_operation(session_id(), Operation.t()) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def submit_operation(session_id, %Operation{} = op) when is_binary(session_id) do
    GenServer.call(via(session_id), {:submit, op, self()})
  end

  @doc """
  Removes the calling process from the session's subscriber list.
  """
  @spec leave(session_id()) :: :ok
  def leave(session_id) when is_binary(session_id) do
    GenServer.cast(via(session_id), {:leave, self()})
  end

  # ---------------------------------------------------------------------------
  # GenServer callbacks
  # ---------------------------------------------------------------------------

  @impl GenServer
  def init(opts) do
    session_id = Keyword.fetch!(opts, :session_id)
    initial_content = Keyword.get(opts, :initial_content, "")

    state = %{
      session_id: session_id,
      document: initial_content,
      revision: 0,
      history: [],
      subscribers: %{}
    }

    {:ok, state, @idle_timeout_ms}
  end

  @impl GenServer
  def handle_call({:join, subscriber_pid}, _from, state) do
    Process.monitor(subscriber_pid)
    updated = put_in(state, [:subscribers, subscriber_pid], %{joined_at: DateTime.utc_now()})
    snapshot = %{document: state.document, revision: state.revision}
    {:reply, {:ok, snapshot}, updated, @idle_timeout_ms}
  end

  def handle_call({:submit, op, from_pid}, _from, state) do
    with {:ok, transformed_op} <- transform_operation(op, state),
         {:ok, new_document} <- Operation.apply(transformed_op, state.document) do
      new_revision = state.revision + 1
      new_state = %{state | document: new_document, revision: new_revision, history: [transformed_op | state.history]}

      broadcast_operation(new_state.subscribers, from_pid, transformed_op, new_revision)

      {:reply, {:ok, new_revision}, new_state, @idle_timeout_ms}
    else
      {:error, reason} ->
        {:reply, {:error, reason}, state, @idle_timeout_ms}
    end
  end

  @impl GenServer
  def handle_cast({:leave, pid}, state) do
    new_state = update_in(state, [:subscribers], &Map.delete(&1, pid))
    {:noreply, new_state, @idle_timeout_ms}
  end

  @impl GenServer
  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    new_state = update_in(state, [:subscribers], &Map.delete(&1, pid))
    {:noreply, new_state, @idle_timeout_ms}
  end

  def handle_info(:timeout, state) do
    Logger.info("Document session idle timeout, shutting down",
      session_id: state.session_id,
      subscriber_count: map_size(state.subscribers)
    )
    {:stop, :normal, state}
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp transform_operation(%Operation{revision: op_revision} = op, %{revision: server_revision, history: history}) do
    concurrent_ops = Enum.take(history, server_revision - op_revision)
    OperationTransformer.transform_against(op, concurrent_ops)
  end

  defp broadcast_operation(subscribers, sender_pid, op, revision) do
    message = {:operation, %{op: op, revision: revision}}

    subscribers
    |> Map.keys()
    |> Enum.reject(&(&1 == sender_pid))
    |> Enum.each(&send(&1, message))
  end

  defp via(session_id), do: {:via, Registry, {Collab.SessionRegistry, session_id}}
end
```
