```elixir
defmodule AppWeb.Plugs.ServerSentEvents do
  @moduledoc """
  A Plug that upgrades an HTTP connection to a Server-Sent Events (SSE)
  stream, allowing the server to push typed events to browser clients over
  a persistent HTTP connection.

  Callers subscribe to a PubSub topic and forward received messages as
  SSE frames. The connection is held open until the client disconnects
  or the server-side process exits. Connection state and keepalive
  scheduling are managed by `AppWeb.Plugs.ServerSentEvents.ConnectionServer`.
  """

  import Plug.Conn

  @behaviour Plug

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, opts) do
    topic        = Keyword.fetch!(opts, :topic)
    pubsub       = Keyword.get(opts, :pubsub, Platform.PubSub)
    event_mapper = Keyword.get(opts, :event_mapper, &default_mapper/1)

    conn =
      conn
      |> put_resp_header("content-type", "text/event-stream")
      |> put_resp_header("cache-control", "no-cache")
      |> put_resp_header("connection", "keep-alive")
      |> put_resp_header("x-accel-buffering", "no")
      |> send_chunked(200)

    {:ok, pid} =
      AppWeb.Plugs.ServerSentEvents.ConnectionServer.start_link(
        conn: conn,
        topic: topic,
        pubsub: pubsub,
        event_mapper: event_mapper
      )

    AppWeb.Plugs.ServerSentEvents.ConnectionServer.await(pid)
  end

  @doc "Encodes a map into a valid SSE frame string."
  @spec encode_event(map()) :: String.t()
  def encode_event(%{event: event, data: data} = opts) do
    id_line    = if id    = Map.get(opts, :id),       do: "id: #{id}\n",         else: ""
    retry_line = if retry = Map.get(opts, :retry_ms), do: "retry: #{retry}\n",   else: ""
    data_encoded = encode_data(data)
    "#{id_line}#{retry_line}event: #{event}\ndata: #{data_encoded}\n\n"
  end

  def encode_event(%{data: data}) do
    "data: #{encode_data(data)}\n\n"
  end

  @spec encode_data(term()) :: String.t()
  defp encode_data(data) when is_map(data) or is_list(data), do: Jason.encode!(data)
  defp encode_data(data), do: to_string(data)

  @spec default_mapper(term()) :: map()
  defp default_mapper(data) when is_map(data), do: %{event: "message", data: data}
  defp default_mapper(data), do: %{event: "message", data: to_string(data)}
end

defmodule AppWeb.Plugs.ServerSentEvents.ConnectionServer do
  @moduledoc """
  GenServer that owns a single SSE connection's lifecycle.

  Responsibilities:
  - Subscribes to the configured PubSub topic on startup.
  - Schedules and sends keepalive comment frames at a fixed interval.
  - Receives domain messages and flushes them as SSE frames via chunked transfer.
  - Terminates cleanly when the client disconnects (chunk returns `{:error, :closed}`).
  - Unblocks the parent Plug process via `await/1` once the connection is done.
  """

  use GenServer

  import Plug.Conn, only: [chunk: 2]

  require Logger

  alias AppWeb.Plugs.ServerSentEvents

  @keepalive_interval_ms 25_000
  @comment_frame ": keepalive\n\n"

  @type opts :: [
    conn: Plug.Conn.t(),
    topic: String.t(),
    pubsub: module(),
    event_mapper: (term() -> map())
  ]

  @spec start_link(opts()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @doc """
  Blocks the calling process until the SSE connection terminates.
  Returns the final `Plug.Conn` so the Plug pipeline can complete.
  """
  @spec await(pid()) :: Plug.Conn.t()
  def await(pid) do
    ref = Process.monitor(pid)

    receive do
      {:connection_done, ^pid, conn} ->
        Process.demonitor(ref, [:flush])
        conn

      {:DOWN, ^ref, :process, ^pid, _reason} ->
        GenServer.call(pid, :get_conn)
    end
  end

  @impl GenServer
  def init(opts) do
    conn         = Keyword.fetch!(opts, :conn)
    topic        = Keyword.fetch!(opts, :topic)
    pubsub       = Keyword.fetch!(opts, :pubsub)
    event_mapper = Keyword.fetch!(opts, :event_mapper)

    Phoenix.PubSub.subscribe(pubsub, topic)
    schedule_keepalive()

    state = %{
      conn:         conn,
      event_mapper: event_mapper,
      caller:       nil
    }

    {:ok, state}
  end

  @impl GenServer
  def handle_call(:get_conn, _from, state) do
    {:reply, state.conn, state}
  end

  @impl GenServer
  def handle_info(:keepalive, state) do
    case chunk(state.conn, @comment_frame) do
      {:ok, conn} ->
        schedule_keepalive()
        {:noreply, %{state | conn: conn}}

      {:error, :closed} ->
        {:stop, :normal, state}
    end
  end

  def handle_info({:sse_event, event_data}, state) do
    frame = ServerSentEvents.encode_event(state.event_mapper.(event_data))
    flush_frame(frame, state)
  end

  def handle_info({:domain_event, payload}, state) do
    frame = ServerSentEvents.encode_event(%{event: "message", data: payload})
    flush_frame(frame, state)
  end

  def handle_info(message, state) do
    Logger.debug("[SSE.ConnectionServer] Unhandled message: #{inspect(message)}")
    {:noreply, state}
  end

  @impl GenServer
  def terminate(_reason, state) do
    if is_pid(state.caller) do
      send(state.caller, {:connection_done, self(), state.conn})
    end

    :ok
  end

  @spec flush_frame(String.t(), map()) :: {:noreply, map()} | {:stop, :normal, map()}
  defp flush_frame(frame, state) do
    case chunk(state.conn, frame) do
      {:ok, conn}         -> {:noreply, %{state | conn: conn}}
      {:error, :closed}   -> {:stop, :normal, state}
    end
  end

  @spec schedule_keepalive() :: reference()
  defp schedule_keepalive do
    Process.send_after(self(), :keepalive, @keepalive_interval_ms)
  end
end

defmodule AppWeb.LiveFeedController do
  @moduledoc """
  Controller that streams live feed events to subscribers via SSE.
  """

  use AppWeb, :controller

  alias AppWeb.Plugs.ServerSentEvents

  plug ServerSentEvents,
       topic: fn conn -> "feed:account:#{conn.assigns.current_account.id}" end,
       pubsub: Platform.PubSub
       when action in [:stream]

  def stream(conn, _params), do: conn
end
```
