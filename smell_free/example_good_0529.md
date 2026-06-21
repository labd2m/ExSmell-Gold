```elixir
defmodule Comms.MessageBus do
  @moduledoc """
  Lightweight synchronous message bus that routes messages between
  named subscribers within a single node. Subscribers register handler
  functions for specific topics. The bus guarantees delivery ordering
  per topic by processing messages serially inside its GenServer. Unlike
  Phoenix PubSub, this bus provides synchronous confirmation that all
  handlers have run before returning to the caller.
  """

  use GenServer

  @type topic :: String.t()
  @type handler_fn :: (term() -> :ok | {:error, term()})
  @type subscription_id :: reference()

  @doc "Starts the message bus registered under its module name."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Subscribes `handler` to messages on `topic`. Returns a subscription ID."
  @spec subscribe(topic(), handler_fn()) :: {:ok, subscription_id()}
  def subscribe(topic, handler)
      when is_binary(topic) and is_function(handler, 1) do
    GenServer.call(__MODULE__, {:subscribe, topic, handler})
  end

  @doc "Removes a subscription by its ID."
  @spec unsubscribe(subscription_id()) :: :ok
  def unsubscribe(sub_id) when is_reference(sub_id) do
    GenServer.cast(__MODULE__, {:unsubscribe, sub_id})
  end

  @doc """
  Publishes `message` to `topic`. All handlers for the topic are called
  synchronously. Returns a list of per-handler results.
  """
  @spec publish(topic(), term()) :: [{:ok, :ok} | {:error, term()}]
  def publish(topic, message) when is_binary(topic) do
    GenServer.call(__MODULE__, {:publish, topic, message})
  end

  @doc "Returns the count of active subscriptions for `topic`."
  @spec subscriber_count(topic()) :: non_neg_integer()
  def subscriber_count(topic) when is_binary(topic) do
    GenServer.call(__MODULE__, {:subscriber_count, topic})
  end

  @impl GenServer
  def init(_opts), do: {:ok, %{subscriptions: %{}}}

  @impl GenServer
  def handle_call({:subscribe, topic, handler}, _from, state) do
    sub_id = make_ref()
    entry = %{id: sub_id, topic: topic, handler: handler}
    new_subs = Map.update(state.subscriptions, topic, [entry], &[entry | &1])
    {:reply, {:ok, sub_id}, %{state | subscriptions: new_subs}}
  end

  def handle_call({:publish, topic, message}, _from, state) do
    handlers = Map.get(state.subscriptions, topic, [])
    results = Enum.map(handlers, fn %{handler: h} -> invoke(h, message) end)
    {:reply, results, state}
  end

  def handle_call({:subscriber_count, topic}, _from, state) do
    count = state.subscriptions |> Map.get(topic, []) |> length()
    {:reply, count, state}
  end

  @impl GenServer
  def handle_cast({:unsubscribe, sub_id}, state) do
    new_subs =
      Map.new(state.subscriptions, fn {topic, entries} ->
        {topic, Enum.reject(entries, fn e -> e.id == sub_id end)}
      end)
      |> Map.reject(fn {_topic, entries} -> Enum.empty?(entries) end)

    {:noreply, %{state | subscriptions: new_subs}}
  end

  defp invoke(handler, message) do
    case handler.(message) do
      :ok -> {:ok, :ok}
      {:error, reason} -> {:error, reason}
    end
  rescue
    e -> {:error, {:handler_raised, Exception.message(e)}}
  end
end
```
