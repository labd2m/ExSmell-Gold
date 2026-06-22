```elixir
defmodule Events.Pubsub.TopicRouter do
  @moduledoc """
  Routes published events to registered subscriber callbacks by topic pattern.
  Supports exact-match and wildcard topic subscriptions.
  Subscription state is managed inside a supervised GenServer.
  """

  use GenServer

  @type topic :: String.t()
  @type handler :: (map() -> :ok | {:error, term()})
  @type subscription :: %{id: String.t(), topic: topic(), handler: handler()}
  @type state :: %{subscriptions: [subscription()]}

  @doc """
  Starts the TopicRouter linked to the calling process.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Subscribes `handler` to events matching `topic`.
  Wildcards are expressed with `*` (e.g. `"orders.*"`).
  Returns `{:ok, subscription_id}`.
  """
  @spec subscribe(topic(), handler()) :: {:ok, String.t()}
  def subscribe(topic, handler) when is_binary(topic) and is_function(handler, 1) do
    GenServer.call(__MODULE__, {:subscribe, topic, handler})
  end

  @doc """
  Removes a subscription by its ID.
  """
  @spec unsubscribe(String.t()) :: :ok
  def unsubscribe(subscription_id) when is_binary(subscription_id) do
    GenServer.cast(__MODULE__, {:unsubscribe, subscription_id})
  end

  @doc """
  Publishes `event` to all subscribers whose topic patterns match `topic`.
  Returns a list of `{subscription_id, result}` pairs.
  """
  @spec publish(topic(), map()) :: [{String.t(), :ok | {:error, term()}}]
  def publish(topic, event) when is_binary(topic) and is_map(event) do
    GenServer.call(__MODULE__, {:publish, topic, event})
  end

  @impl GenServer
  def init(_opts), do: {:ok, %{subscriptions: []}}

  @impl GenServer
  def handle_call({:subscribe, topic, handler}, _from, state) do
    id = generate_id()
    sub = %{id: id, topic: topic, handler: handler}
    {:reply, {:ok, id}, %{state | subscriptions: [sub | state.subscriptions]}}
  end

  @impl GenServer
  def handle_call({:publish, topic, event}, _from, state) do
    results =
      state.subscriptions
      |> Enum.filter(fn sub -> topic_matches?(sub.topic, topic) end)
      |> Enum.map(fn sub -> {sub.id, invoke_handler(sub.handler, event)} end)

    {:reply, results, state}
  end

  @impl GenServer
  def handle_cast({:unsubscribe, subscription_id}, state) do
    updated = Enum.reject(state.subscriptions, fn s -> s.id == subscription_id end)
    {:noreply, %{state | subscriptions: updated}}
  end

  defp topic_matches?(pattern, topic) do
    pattern_parts = String.split(pattern, ".")
    topic_parts = String.split(topic, ".")

    if length(pattern_parts) != length(topic_parts) do
      false
    else
      Enum.zip(pattern_parts, topic_parts)
      |> Enum.all?(fn {p, t} -> p == "*" or p == t end)
    end
  end

  defp invoke_handler(handler, event) do
    handler.(event)
  rescue
    e -> {:error, {:handler_exception, Exception.message(e)}}
  end

  defp generate_id do
    :crypto.strong_rand_bytes(16) |> Base.hex_encode32(case: :lower, padding: false)
  end
end
```
