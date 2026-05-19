# Code Smell: Unsupervised Process

- **Smell name:** Unsupervised Process
- **Expected smell location:** `ConnectionHandler.start/2`
- **Affected function(s):** `ConnectionHandler.start/2`, `WebSocketServer.on_connect/2`
- **Short explanation:** Each inbound WebSocket connection gets its own `GenServer` to manage message queuing, ping/pong keepalive, and graceful drain. `GenServer.start/3` is used with no supervisor, so a handler crash is invisible to the platform — the connection is silently dropped without any cleanup, close frame, or reconnect hint to the client.

```elixir
defmodule ConnectionHandler do
  use GenServer

  @moduledoc """
  Manages the server-side state of a single WebSocket connection.
  Handles message queuing, backpressure, keepalive ping/pong,
  and graceful shutdown with drain support.
  """

  @ping_interval_ms 25_000
  @pong_timeout_ms 10_000
  @max_queue_size 500

  defstruct [
    :connection_id,
    :user_id,
    :remote_ip,
    :connected_at,
    :socket_pid,
    :status,
    :last_ping_at,
    :last_pong_at,
    outbound_queue: :queue.new(),
    queue_size: 0,
    bytes_sent: 0,
    bytes_received: 0,
    message_count: 0
  ]

  # VALIDATION: SMELL START - Unsupervised Process
  # VALIDATION: This is a smell because one `GenServer` is spawned per active
  # WebSocket connection via `GenServer.start/3` with no supervisor. A server
  # handling thousands of concurrent connections creates thousands of unsupervised
  # processes. A crash in any handler silently terminates the connection with no
  # close frame sent to the client, no cleanup of associated resources, and no
  # way for an operator to observe or recover the failure.
  def start(connection_id, attrs) do
    GenServer.start(
      __MODULE__,
      Map.put(attrs, :connection_id, connection_id),
      name: via(connection_id)
    )
  end
  # VALIDATION: SMELL END

  def push(connection_id, message) do
    GenServer.call(via(connection_id), {:push, message})
  end

  def receive_message(connection_id, raw) do
    GenServer.cast(via(connection_id), {:received, raw})
  end

  def receive_pong(connection_id) do
    GenServer.cast(via(connection_id), :pong)
  end

  def drain_and_close(connection_id) do
    GenServer.call(via(connection_id), :drain_close, 30_000)
  end

  def info(connection_id) do
    GenServer.call(via(connection_id), :info)
  end

  defp via(id), do: {:via, Registry, {ConnectionRegistry, id}}

  ## Callbacks

  @impl true
  def init(%{connection_id: id, user_id: uid, remote_ip: ip, socket_pid: spid}) do
    state = %__MODULE__{
      connection_id: id,
      user_id: uid,
      remote_ip: ip,
      socket_pid: spid,
      connected_at: DateTime.utc_now(),
      status: :connected
    }

    schedule_ping()
    {:ok, state}
  end

  @impl true
  def handle_call({:push, message}, _from, %{status: :connected} = state) do
    if state.queue_size >= @max_queue_size do
      {:reply, {:error, :queue_full}, state}
    else
      encoded = encode(message)
      send(state.socket_pid, {:ws_push, encoded})

      {:reply, :ok, %{state |
        queue_size: state.queue_size + 1,
        bytes_sent: state.bytes_sent + byte_size(encoded),
        message_count: state.message_count + 1
      }}
    end
  end

  def handle_call({:push, _message}, _from, state) do
    {:reply, {:error, :connection_closed}, state}
  end

  def handle_call(:drain_close, _from, state) do
    flush_queue(state)
    send(state.socket_pid, :ws_close)
    {:reply, :ok, %{state | status: :closed}}
  end

  def handle_call(:info, _from, state) do
    info = %{
      connection_id: state.connection_id,
      user_id: state.user_id,
      remote_ip: state.remote_ip,
      status: state.status,
      connected_at: state.connected_at,
      bytes_sent: state.bytes_sent,
      bytes_received: state.bytes_received,
      message_count: state.message_count
    }

    {:reply, info, state}
  end

  @impl true
  def handle_cast({:received, raw}, state) do
    size = byte_size(raw)
    _decoded = decode(raw)

    {:noreply, %{state | bytes_received: state.bytes_received + size}}
  end

  def handle_cast(:pong, state) do
    {:noreply, %{state | last_pong_at: DateTime.utc_now()}}
  end

  @impl true
  def handle_info(:ping, %{status: :connected} = state) do
    send(state.socket_pid, :ws_ping)
    now = DateTime.utc_now()
    Process.send_after(self(), :pong_timeout, @pong_timeout_ms)
    schedule_ping()
    {:noreply, %{state | last_ping_at: now}}
  end

  def handle_info(:ping, state), do: {:noreply, state}

  def handle_info(:pong_timeout, %{last_pong_at: nil} = state) do
    send(state.socket_pid, :ws_close)
    {:stop, :normal, %{state | status: :timed_out}}
  end

  def handle_info(:pong_timeout, state) do
    elapsed = DateTime.diff(DateTime.utc_now(), state.last_pong_at, :millisecond)

    if elapsed > @pong_timeout_ms do
      send(state.socket_pid, :ws_close)
      {:stop, :normal, %{state | status: :timed_out}}
    else
      {:noreply, state}
    end
  end

  defp flush_queue(_state), do: :ok
  defp encode(message), do: :erlang.term_to_binary(message)
  defp decode(raw), do: :erlang.binary_to_term(raw, [:safe])

  defp schedule_ping do
    Process.send_after(self(), :ping, @ping_interval_ms)
  end
end

defmodule WebSocketServer do
  @moduledoc "Accepts WebSocket upgrade requests and boots connection handlers."

  def on_connect(connection_id, %{user_id: uid, remote_ip: ip, socket_pid: spid}) do
    attrs = %{user_id: uid, remote_ip: ip, socket_pid: spid}

    case ConnectionHandler.start(connection_id, attrs) do
      {:ok, _pid} ->
        {:ok, connection_id}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def on_message(connection_id, raw_frame) do
    ConnectionHandler.receive_message(connection_id, raw_frame)
  end

  def on_disconnect(connection_id) do
    ConnectionHandler.drain_and_close(connection_id)
  end
end
```
