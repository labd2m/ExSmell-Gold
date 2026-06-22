```elixir
defmodule Events.LocalBus do
  @moduledoc """
  A lightweight in-process pub/sub bus backed by Registry.
  Processes subscribe to named topics and receive messages via
  standard Elixir message passing, with no external broker dependency.
  """

  use GenServer

  @registry Events.LocalBus.Registry

  @type topic :: String.t()
  @type event :: %{topic: topic(), payload: map(), published_at: DateTime.t()}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec subscribe(topic()) :: :ok
  def subscribe(topic) when is_binary(topic) do
    Registry.register(@registry, topic, [])
    :ok
  end

  @spec unsubscribe(topic()) :: :ok
  def unsubscribe(topic) when is_binary(topic) do
    Registry.unregister(@registry, topic)
    :ok
  end

  @spec publish(topic(), map()) :: {:ok, non_neg_integer()}
  def publish(topic, payload) when is_binary(topic) and is_map(payload) do
    GenServer.call(__MODULE__, {:publish, topic, payload})
  end

  @spec publish_async(topic(), map()) :: :ok
  def publish_async(topic, payload) when is_binary(topic) and is_map(payload) do
    GenServer.cast(__MODULE__, {:publish, topic, payload})
  end

  @spec subscriber_count(topic()) :: non_neg_integer()
  def subscriber_count(topic) when is_binary(topic) do
    Registry.count_match(@registry, topic, :_)
  end

  @spec subscribed_topics() :: [topic()]
  def subscribed_topics do
    @registry
    |> Registry.keys(self())
    |> Enum.uniq()
  end

  @impl GenServer
  def init(_opts) do
    {:ok, %{published_count: 0}}
  end

  @impl GenServer
  def handle_call({:publish, topic, payload}, _from, state) do
    count = dispatch(topic, payload)
    {:reply, {:ok, count}, %{state | published_count: state.published_count + 1}}
  end

  @impl GenServer
  def handle_cast({:publish, topic, payload}, state) do
    dispatch(topic, payload)
    {:noreply, %{state | published_count: state.published_count + 1}}
  end

  @spec dispatch(topic(), map()) :: non_neg_integer()
  defp dispatch(topic, payload) do
    event = %{topic: topic, payload: payload, published_at: DateTime.utc_now()}

    subscribers = Registry.lookup(@registry, topic)

    Enum.each(subscribers, fn {pid, _} ->
      send(pid, {:bus_event, event})
    end)

    length(subscribers)
  end
end

defmodule Events.LocalBus.Supervisor do
  @moduledoc "Supervision tree for the local event bus."

  use Supervisor

  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl Supervisor
  def init(_opts) do
    children = [
      {Registry, keys: :duplicate, name: Events.LocalBus.Registry},
      Events.LocalBus
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
```
