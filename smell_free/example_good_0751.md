```elixir
defmodule EventBridge.Route do
  @moduledoc false

  @type transformer :: (map() -> {:ok, map()} | :drop)

  @type t :: %__MODULE__{
          source_topic: String.t(),
          target_topic: String.t(),
          target_pubsub: atom(),
          transformer: transformer() | nil
        }

  defstruct [:source_topic, :target_topic, :target_pubsub, :transformer]

  @spec new(String.t(), String.t(), atom(), transformer() | nil) :: t()
  def new(source_topic, target_topic, target_pubsub, transformer \\ nil) do
    %__MODULE__{
      source_topic: source_topic,
      target_topic: target_topic,
      target_pubsub: target_pubsub,
      transformer: transformer
    }
  end
end

defmodule EventBridge do
  @moduledoc """
  Routes events from one Phoenix.PubSub bus to another, optionally
  applying a transformation function before forwarding.

  Each route subscribes to a source topic on one PubSub instance and
  re-publishes matching events to a target topic on a (possibly different)
  PubSub instance. The transformer function can enrich, filter, or reshape
  the event; returning `:drop` suppresses forwarding entirely.
  """

  use GenServer

  require Logger

  alias EventBridge.Route

  @type opts :: [
          source_pubsub: atom(),
          routes: [Route.t()]
        ]

  @spec start_link(opts()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec add_route(Route.t()) :: :ok
  def add_route(%Route{} = route) do
    GenServer.call(__MODULE__, {:add_route, route})
  end

  @spec remove_route(String.t()) :: :ok
  def remove_route(source_topic) when is_binary(source_topic) do
    GenServer.cast(__MODULE__, {:remove_route, source_topic})
  end

  @impl GenServer
  def init(opts) do
    source_pubsub = Keyword.fetch!(opts, :source_pubsub)
    routes = Keyword.get(opts, :routes, [])

    Enum.each(routes, fn route ->
      Phoenix.PubSub.subscribe(source_pubsub, route.source_topic)
    end)

    state = %{source_pubsub: source_pubsub, routes: Map.new(routes, &{&1.source_topic, &1})}
    {:ok, state}
  end

  @impl GenServer
  def handle_call({:add_route, %Route{} = route}, _from, state) do
    Phoenix.PubSub.subscribe(state.source_pubsub, route.source_topic)
    updated_routes = Map.put(state.routes, route.source_topic, route)
    {:reply, :ok, %{state | routes: updated_routes}}
  end

  @impl GenServer
  def handle_cast({:remove_route, source_topic}, state) do
    Phoenix.PubSub.unsubscribe(state.source_pubsub, source_topic)
    {:noreply, %{state | routes: Map.delete(state.routes, source_topic)}}
  end

  @impl GenServer
  def handle_info({:event, event}, state) do
    topic = Map.get(event, :topic) || Map.get(event, "topic")

    case Map.fetch(state.routes, topic) do
      {:ok, route} -> forward(route, event)
      :error -> :ok
    end

    {:noreply, state}
  end

  def handle_info({:pubsub_forward, topic, event}, state) do
    case Map.fetch(state.routes, topic) do
      {:ok, route} -> forward(route, event)
      :error -> :ok
    end

    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp forward(%Route{transformer: nil, target_pubsub: pubsub, target_topic: topic}, event) do
    Phoenix.PubSub.broadcast(pubsub, topic, {:event, event})
  end

  defp forward(%Route{transformer: transform, target_pubsub: pubsub, target_topic: topic}, event) do
    case transform.(event) do
      {:ok, transformed} ->
        Phoenix.PubSub.broadcast(pubsub, topic, {:event, transformed})

      :drop ->
        Logger.debug("EventBridge: event dropped by transformer", topic: topic)
    end
  end
end
```
