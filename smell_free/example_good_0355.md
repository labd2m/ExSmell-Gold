```elixir
defmodule Realtime.EventBroadcaster do
  @moduledoc """
  Routes typed domain events to named Phoenix channels using a configurable
  routing table. Each event type maps to one or more channel topics. The
  broadcaster enriches every outbound message with a server-generated
  correlation ID and a UTC timestamp before dispatch. Unknown event types
  are logged and discarded rather than crashing the process.
  """

  use GenServer

  require Logger

  @type event_type :: atom()
  @type topic :: String.t()
  @type routing_table :: %{event_type() => [topic()]}
  @type event :: %{type: event_type(), payload: map()}

  @doc "Starts the broadcaster with the given routing table."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Broadcasts `event` to all topics mapped for its type."
  @spec broadcast(event()) :: :ok | {:error, :unknown_event_type}
  def broadcast(%{type: type, payload: _} = event) when is_atom(type) do
    GenServer.call(__MODULE__, {:broadcast, event})
  end

  @doc "Adds or replaces the topic list for `event_type` in the routing table."
  @spec add_route(event_type(), [topic()]) :: :ok
  def add_route(event_type, topics) when is_atom(event_type) and is_list(topics) do
    GenServer.cast(__MODULE__, {:add_route, event_type, topics})
  end

  @doc "Returns the current routing table."
  @spec routing_table() :: routing_table()
  def routing_table, do: GenServer.call(__MODULE__, :routing_table)

  @impl GenServer
  def init(opts) do
    table = Keyword.get(opts, :routing_table, default_routing_table())
    {:ok, %{routing_table: table}}
  end

  @impl GenServer
  def handle_call({:broadcast, %{type: type} = event}, _from, state) do
    case Map.get(state.routing_table, type) do
      nil ->
        Logger.warning("[EventBroadcaster] No route for event type: #{type}")
        {:reply, {:error, :unknown_event_type}, state}

      topics ->
        envelope = build_envelope(event)
        Enum.each(topics, fn topic -> dispatch(topic, envelope) end)
        {:reply, :ok, state}
    end
  end

  def handle_call(:routing_table, _from, state) do
    {:reply, state.routing_table, state}
  end

  @impl GenServer
  def handle_cast({:add_route, event_type, topics}, state) do
    {:noreply, put_in(state, [:routing_table, event_type], topics)}
  end

  defp build_envelope(%{type: type, payload: payload}) do
    %{
      correlation_id: generate_id(),
      event_type: Atom.to_string(type),
      payload: payload,
      server_time: DateTime.to_iso8601(DateTime.utc_now())
    }
  end

  defp dispatch(topic, envelope) do
    Phoenix.PubSub.broadcast(MyApp.PubSub, topic, {:event, envelope})
  rescue
    e -> Logger.error("[EventBroadcaster] Dispatch to #{topic} failed: #{Exception.message(e)}")
  end

  defp generate_id do
    :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
  end

  defp default_routing_table do
    Application.get_env(:my_app, :event_routing_table, %{})
  end
end
```
