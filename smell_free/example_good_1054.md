```elixir
defmodule Events.Bus.Dispatcher do
  @moduledoc """
  An in-process event bus that routes domain events to registered subscribers.
  Subscribers are registered with a topic and a handler function. All subscriptions
  and dispatches are coordinated through a supervised GenServer to ensure
  consistent state and ordered delivery within a topic.
  """

  use GenServer

  alias Events.Bus.{Subscription, DispatchResult}

  @type handler :: (map() -> :ok | {:error, term()})
  @type topic :: String.t()
  @type state :: %{subscriptions: %{topic() => [Subscription.t()]}}

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @doc "Starts the event bus dispatcher."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, %{subscriptions: %{}}, name: name)
  end

  @doc "Registers `handler` to receive events published to `topic`."
  @spec subscribe(GenServer.server(), topic(), handler()) :: {:ok, String.t()}
  def subscribe(server \\ __MODULE__, topic, handler)
      when is_binary(topic) and is_function(handler, 1) do
    GenServer.call(server, {:subscribe, topic, handler})
  end

  @doc "Cancels a subscription by its ID."
  @spec unsubscribe(GenServer.server(), String.t()) :: :ok
  def unsubscribe(server \\ __MODULE__, subscription_id) when is_binary(subscription_id) do
    GenServer.call(server, {:unsubscribe, subscription_id})
  end

  @doc "Publishes `event` to all handlers subscribed to `topic`."
  @spec publish(GenServer.server(), topic(), map()) :: DispatchResult.t()
  def publish(server \\ __MODULE__, topic, event)
      when is_binary(topic) and is_map(event) do
    GenServer.call(server, {:publish, topic, event})
  end

  # ---------------------------------------------------------------------------
  # GenServer callbacks
  # ---------------------------------------------------------------------------

  @impl GenServer
  def init(state), do: {:ok, state}

  @impl GenServer
  def handle_call({:subscribe, topic, handler}, _from, state) do
    sub = %Subscription{id: generate_id(), topic: topic, handler: handler}
    updated = Map.update(state.subscriptions, topic, [sub], &[sub | &1])
    {:reply, {:ok, sub.id}, %{state | subscriptions: updated}}
  end

  def handle_call({:unsubscribe, id}, _from, state) do
    updated =
      Map.new(state.subscriptions, fn {topic, subs} ->
        {topic, Enum.reject(subs, &(&1.id == id))}
      end)

    {:reply, :ok, %{state | subscriptions: updated}}
  end

  def handle_call({:publish, topic, event}, _from, state) do
    subs = Map.get(state.subscriptions, topic, [])
    results = Enum.map(subs, &invoke_handler(&1, event))

    result = %DispatchResult{
      topic: topic,
      delivered: Enum.count(results, &(&1 == :ok)),
      failed: Enum.count(results, &(&1 != :ok))
    }

    {:reply, result, state}
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  @spec invoke_handler(Subscription.t(), map()) :: :ok | {:error, term()}
  defp invoke_handler(%Subscription{handler: handler}, event) do
    handler.(event)
  rescue
    exception -> {:error, exception}
  end

  @spec generate_id() :: String.t()
  defp generate_id do
    :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
  end
end

defmodule Events.Bus.Subscription do
  @moduledoc false
  @enforce_keys [:id, :topic, :handler]
  defstruct [:id, :topic, :handler]
  @type t :: %__MODULE__{id: String.t(), topic: String.t(), handler: function()}
end

defmodule Events.Bus.DispatchResult do
  @moduledoc "Summary of a single publish operation."
  defstruct [:topic, :delivered, :failed]
  @type t :: %__MODULE__{topic: String.t(), delivered: non_neg_integer(), failed: non_neg_integer()}
end
```
