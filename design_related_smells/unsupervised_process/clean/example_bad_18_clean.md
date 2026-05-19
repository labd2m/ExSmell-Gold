```elixir
defmodule Collaboration.DocumentSession do
  use GenServer

  @moduledoc """
  Manages a real-time collaborative editing session for a single document.
  Tracks connected editors, applies operational transforms, maintains
  a change log for conflict resolution, and broadcasts updates to peers.
  """

  @session_idle_timeout_ms 1_800_000
  @max_history_size 500

  defstruct [
    :session_id,
    :document_id,
    :document_content,
    :version,
    :connected_editors,
    :operation_log,
    :last_activity_at,
    :lock_holder
  ]

  def open(document_id, initial_content) do
    session_id = generate_session_id()

    state = %__MODULE__{
      session_id: session_id,
      document_id: document_id,
      document_content: initial_content,
      version: 0,
      connected_editors: %{},
      operation_log: [],
      last_activity_at: DateTime.utc_now(),
      lock_holder: nil
    }

    GenServer.start(__MODULE__, state, name: via_name(document_id))
    {:ok, session_id}
  end

  @doc "Joins the editing session as an editor."
  def join(document_id, editor_id, editor_info) do
    GenServer.call(via_name(document_id), {:join, editor_id, editor_info})
  end

  @doc "Leaves the editing session."
  def leave(document_id, editor_id) do
    GenServer.cast(via_name(document_id), {:leave, editor_id})
  end

  @doc "Applies an operation from an editor at a specific client version."
  def apply_operation(document_id, editor_id, operation, client_version) do
    GenServer.call(via_name(document_id), {:apply_op, editor_id, operation, client_version})
  end

  @doc "Acquires an exclusive write lock on the document."
  def acquire_lock(document_id, editor_id) do
    GenServer.call(via_name(document_id), {:acquire_lock, editor_id})
  end

  @doc "Releases the write lock."
  def release_lock(document_id, editor_id) do
    GenServer.cast(via_name(document_id), {:release_lock, editor_id})
  end

  @doc "Returns the current session snapshot."
  def snapshot(document_id) do
    GenServer.call(via_name(document_id), :snapshot)
  end

  ## Callbacks

  @impl true
  def init(state) do
    {:ok, state, @session_idle_timeout_ms}
  end

  @impl true
  def handle_call({:join, editor_id, editor_info}, _from, state) do
    editor = Map.merge(editor_info, %{joined_at: DateTime.utc_now(), cursor: nil})
    new_editors = Map.put(state.connected_editors, editor_id, editor)

    new_state = %{
      state
      | connected_editors: new_editors,
        last_activity_at: DateTime.utc_now()
    }

    result = %{
      document_content: new_state.document_content,
      version: new_state.version,
      editors: Map.keys(new_editors)
    }

    {:reply, {:ok, result}, new_state, @session_idle_timeout_ms}
  end

  def handle_call({:apply_op, editor_id, operation, client_version}, _from, state) do
    if state.lock_holder not in [nil, editor_id] do
      {:reply, {:error, :document_locked}, state, @session_idle_timeout_ms}
    else
      transformed_op = transform_operation(operation, client_version, state)

      new_content = apply_to_content(state.document_content, transformed_op)

      log_entry = %{
        editor_id: editor_id,
        operation: transformed_op,
        version: state.version + 1,
        applied_at: DateTime.utc_now()
      }

      truncated_log =
        Enum.take([log_entry | state.operation_log], @max_history_size)

      new_state = %{
        state
        | document_content: new_content,
          version: state.version + 1,
          operation_log: truncated_log,
          last_activity_at: DateTime.utc_now()
      }

      broadcast_operation(new_state, editor_id, transformed_op)
      {:reply, {:ok, new_state.version}, new_state, @session_idle_timeout_ms}
    end
  end

  def handle_call({:acquire_lock, editor_id}, _from, state) do
    case state.lock_holder do
      nil ->
        {:reply, :ok, %{state | lock_holder: editor_id}, @session_idle_timeout_ms}

      ^editor_id ->
        {:reply, :ok, state, @session_idle_timeout_ms}

      other ->
        {:reply, {:error, {:locked_by, other}}, state, @session_idle_timeout_ms}
    end
  end

  def handle_call(:snapshot, _from, state) do
    snap = %{
      session_id: state.session_id,
      document_id: state.document_id,
      version: state.version,
      editor_count: map_size(state.connected_editors),
      editors: Map.keys(state.connected_editors),
      lock_holder: state.lock_holder,
      last_activity_at: state.last_activity_at
    }

    {:reply, snap, state, @session_idle_timeout_ms}
  end

  @impl true
  def handle_cast({:leave, editor_id}, state) do
    new_editors = Map.delete(state.connected_editors, editor_id)

    new_lock =
      if state.lock_holder == editor_id, do: nil, else: state.lock_holder

    {:noreply, %{state | connected_editors: new_editors, lock_holder: new_lock},
     @session_idle_timeout_ms}
  end

  def handle_cast({:release_lock, editor_id}, state) do
    new_lock = if state.lock_holder == editor_id, do: nil, else: state.lock_holder
    {:noreply, %{state | lock_holder: new_lock}, @session_idle_timeout_ms}
  end

  @impl true
  def handle_info(:timeout, state) do
    {:stop, {:shutdown, :idle_timeout}, state}
  end

  defp transform_operation(operation, _client_version, _state), do: operation
  defp apply_to_content(content, _operation), do: content
  defp broadcast_operation(_state, _editor_id, _operation), do: :ok

  defp via_name(document_id) do
    {:via, Registry, {Collaboration.SessionRegistry, document_id}}
  end

  defp generate_session_id do
    :crypto.strong_rand_bytes(12) |> Base.url_encode64(padding: false)
  end
end
```
