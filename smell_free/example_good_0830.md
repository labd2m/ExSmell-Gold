```elixir
defmodule GraphQL.Subscription.Subscription do
  @moduledoc false

  @type t :: %__MODULE__{
          id: String.t(),
          topic: String.t(),
          subscriber: pid(),
          document: String.t(),
          variables: map(),
          created_at: integer()
        }

  defstruct [:id, :topic, :subscriber, :document, :variables, :created_at]
end

defmodule GraphQL.Subscription.Registry do
  @moduledoc """
  Manages active GraphQL subscriptions, routing topic broadcasts to the
  correct subscriber processes.

  Each subscription is keyed by an ID. Subscriber processes are monitored
  so that subscriptions are automatically cleaned up when the subscribing
  process (e.g. a WebSocket channel) exits. Broadcasting to a topic
  delivers the payload to every active subscription on that topic.
  """

  use GenServer

  alias GraphQL.Subscription.Subscription

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec subscribe(String.t(), String.t(), map(), pid()) :: {:ok, String.t()}
  def subscribe(topic, document, variables \\ %{}, subscriber \\ self())
      when is_binary(topic) and is_binary(document) and is_pid(subscriber) do
    GenServer.call(__MODULE__, {:subscribe, topic, document, variables, subscriber})
  end

  @spec unsubscribe(String.t()) :: :ok
  def unsubscribe(subscription_id) when is_binary(subscription_id) do
    GenServer.cast(__MODULE__, {:unsubscribe, subscription_id})
  end

  @spec broadcast(String.t(), term()) :: :ok
  def broadcast(topic, payload) when is_binary(topic) do
    GenServer.cast(__MODULE__, {:broadcast, topic, payload})
  end

  @spec active_count() :: non_neg_integer()
  def active_count, do: GenServer.call(__MODULE__, :active_count)

  @spec subscriptions_for_topic(String.t()) :: [String.t()]
  def subscriptions_for_topic(topic) when is_binary(topic) do
    GenServer.call(__MODULE__, {:for_topic, topic})
  end

  @impl GenServer
  def init(_opts) do
    {:ok, %{subscriptions: %{}, monitors: %{}}}
  end

  @impl GenServer
  def handle_call({:subscribe, topic, document, variables, pid}, _from, state) do
    id = generate_id()
    ref = Process.monitor(pid)

    sub = %Subscription{
      id: id,
      topic: topic,
      subscriber: pid,
      document: document,
      variables: variables,
      created_at: System.system_time(:millisecond)
    }

    state = %{state |
      subscriptions: Map.put(state.subscriptions, id, sub),
      monitors: Map.put(state.monitors, ref, id)
    }

    {:reply, {:ok, id}, state}
  end

  def handle_call(:active_count, _from, state) do
    {:reply, map_size(state.subscriptions), state}
  end

  def handle_call({:for_topic, topic}, _from, state) do
    ids =
      state.subscriptions
      |> Enum.filter(fn {_, sub} -> sub.topic == topic end)
      |> Enum.map(fn {id, _} -> id end)

    {:reply, ids, state}
  end

  @impl GenServer
  def handle_cast({:unsubscribe, id}, state) do
    {:noreply, remove_subscription(state, id)}
  end

  def handle_cast({:broadcast, topic, payload}, state) do
    state.subscriptions
    |> Enum.filter(fn {_, sub} -> sub.topic == topic end)
    |> Enum.each(fn {_id, sub} ->
      send(sub.subscriber, {:subscription_data, sub.id, topic, payload})
    end)

    {:noreply, state}
  end

  @impl GenServer
  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    case Map.fetch(state.monitors, ref) do
      {:ok, id} ->
        state = %{state | monitors: Map.delete(state.monitors, ref)}
        {:noreply, remove_subscription(state, id)}

      :error ->
        {:noreply, state}
    end
  end

  defp remove_subscription(state, id) do
    sub = Map.get(state.subscriptions, id)

    monitors =
      if sub do
        Enum.reject(state.monitors, fn {_, sid} -> sid == id end) |> Map.new()
      else
        state.monitors
      end

    %{state | subscriptions: Map.delete(state.subscriptions, id), monitors: monitors}
  end

  defp generate_id do
    :crypto.strong_rand_bytes(12) |> Base.url_encode64(padding: false)
  end
end
```
