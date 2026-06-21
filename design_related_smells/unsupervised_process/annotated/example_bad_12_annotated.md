# Annotated Example 12 — Unsupervised Process

- **Smell name:** Unsupervised Process
- **Expected smell location:** `WebSocket.ConnectionHandler.start/2`
- **Affected function(s):** `start/2`
- **Short explanation:** Each WebSocket client connection spawns its own long-running GenServer via `GenServer.start/3` outside a supervision tree. In a high-traffic system, hundreds of these unsupervised processes accumulate, and any crash silently drops a client connection with no recovery mechanism.

```elixir
defmodule WebSocket.ConnectionHandler do
  use GenServer

  @moduledoc """
  Manages the lifecycle of a single WebSocket client connection.
  Handles message routing, subscription state, heartbeat acknowledgement,
  and graceful disconnection with draining of queued messages.
  """

  @ping_interval_ms 25_000
  @max_queue_size 500

  defstruct [
    :conn_id,
    :user_id,
    :socket_ref,
    :subscriptions,
    :outbound_queue,
    :last_ping_at,
    :last_pong_at,
    :message_count,
    :connected_at
  ]

  # VALIDATION: SMELL START - Unsupervised Process
  # VALIDATION: This is a smell because `GenServer.start/3` creates a long-running
  # connection handler for every active WebSocket client, entirely outside a
  # supervision tree. When many clients are connected simultaneously, there are many
  # such unsupervised processes. If a handler crashes (e.g., due to a malformed
  # subscription message), the client's connection state is lost. No supervisor
  # is present to clean up or restart the process, potentially leaking resources
  # and leaving orphaned subscription records.
  def start(conn_id, socket_ref, opts \\ []) do
    state = %__MODULE__{
      conn_id: conn_id,
      user_id: Keyword.get(opts, :user_id),
      socket_ref: socket_ref,
      subscriptions: MapSet.new(),
      outbound_queue: :queue.new(),
      last_ping_at: nil,
      last_pong_at: nil,
      message_count: 0,
      connected_at: DateTime.utc_now()
    }

    GenServer.start(__MODULE__, state, name: via_name(conn_id))
  end
  # VALIDATION: SMELL END

  @doc "Enqueues an outbound message to the connected client."
  def push(conn_id, message) do
    GenServer.cast(via_name(conn_id), {:push, message})
  end

  @doc "Processes an inbound message from the client."
  def receive_message(conn_id, payload) do
    GenServer.cast(via_name(conn_id), {:inbound, payload})
  end

  @doc "Acknowledges a pong response from the client."
  def pong(conn_id) do
    GenServer.cast(via_name(conn_id), :pong)
  end

  @doc "Subscribes the connection to a named topic."
  def subscribe(conn_id, topic) do
    GenServer.call(via_name(conn_id), {:subscribe, topic})
  end

  @doc "Unsubscribes from a named topic."
  def unsubscribe(conn_id, topic) do
    GenServer.call(via_name(conn_id), {:unsubscribe, topic})
  end

  @doc "Returns connection metadata and current subscription list."
  def info(conn_id) do
    GenServer.call(via_name(conn_id), :info)
  end

  @doc "Gracefully closes the connection after flushing queued messages."
  def disconnect(conn_id) do
    GenServer.cast(via_name(conn_id), :disconnect)
  end

  ## Callbacks

  @impl true
  def init(state) do
    schedule_ping()
    {:ok, state}
  end

  @impl true
  def handle_cast({:push, message}, state) do
    if :queue.len(state.outbound_queue) < @max_queue_size do
      new_queue = :queue.in(message, state.outbound_queue)
      send(self(), :flush)
      {:noreply, %{state | outbound_queue: new_queue}}
    else
      {:noreply, state}
    end
  end

  def handle_cast({:inbound, payload}, state) do
    handle_inbound(payload, state)
  end

  def handle_cast(:pong, state) do
    {:noreply, %{state | last_pong_at: DateTime.utc_now()}}
  end

  def handle_cast(:disconnect, state) do
    {:stop, :normal, state}
  end

  @impl true
  def handle_call({:subscribe, topic}, _from, state) do
    {:reply, :ok, %{state | subscriptions: MapSet.put(state.subscriptions, topic)}}
  end

  def handle_call({:unsubscribe, topic}, _from, state) do
    {:reply, :ok, %{state | subscriptions: MapSet.delete(state.subscriptions, topic)}}
  end

  def handle_call(:info, _from, state) do
    info = %{
      conn_id: state.conn_id,
      user_id: state.user_id,
      subscriptions: MapSet.to_list(state.subscriptions),
      message_count: state.message_count,
      queue_depth: :queue.len(state.outbound_queue),
      connected_at: state.connected_at,
      last_ping_at: state.last_ping_at,
      last_pong_at: state.last_pong_at
    }

    {:reply, info, state}
  end

  @impl true
  def handle_info(:flush, state) do
    new_state = drain_queue(state)
    {:noreply, new_state}
  end

  def handle_info(:ping, state) do
    # Send ping to socket (simulated)
    send_to_socket(state.socket_ref, :ping)
    schedule_ping()

    {:noreply, %{state | last_ping_at: DateTime.utc_now()}}
  end

  defp handle_inbound(%{"type" => "message", "data" => data}, state) do
    {:noreply, %{state | message_count: state.message_count + 1}}
  end

  defp handle_inbound(%{"type" => "subscribe", "topic" => topic}, state) do
    {:noreply, %{state | subscriptions: MapSet.put(state.subscriptions, topic)}}
  end

  defp handle_inbound(_unknown, state), do: {:noreply, state}

  defp drain_queue(state) do
    case :queue.out(state.outbound_queue) do
      {{:value, message}, new_queue} ->
        send_to_socket(state.socket_ref, message)
        drain_queue(%{state | outbound_queue: new_queue})

      {:empty, _} ->
        state
    end
  end

  defp send_to_socket(_ref, _message), do: :ok

  defp schedule_ping do
    Process.send_after(self(), :ping, @ping_interval_ms)
  end

  defp via_name(conn_id) do
    {:via, Registry, {WebSocket.ConnectionRegistry, conn_id}}
  end
end
```
