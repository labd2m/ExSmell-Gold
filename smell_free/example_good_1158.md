```elixir
defmodule Events.PubSub do
  @moduledoc """
  Lightweight topic-based publish/subscribe system built on `Registry`.

  Processes subscribe to named topics and receive tagged messages when any
  publisher broadcasts to that topic. Subscriptions are process-scoped and
  cleaned up automatically when the subscribing process terminates, requiring
  no manual lifecycle management by callers.

  ## Setup

  Include this module in your application supervision tree:

      children = [Events.PubSub]
      Supervisor.start_link(children, strategy: :one_for_one)

  ## Example

      Events.PubSub.subscribe("orders:placed")
      Events.PubSub.broadcast("orders:placed", %{order_id: "abc"})
      # Subscribing process receives: {:pubsub_message, "orders:placed", %{order_id: "abc"}}
  """

  @registry __MODULE__.Registry
  @message_tag :pubsub_message

  @type topic :: String.t()
  @type message :: term()

  @doc "Returns the child spec for starting the PubSub registry under a supervisor."
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(_opts) do
    Registry.child_spec(keys: :duplicate, name: @registry)
  end

  @doc """
  Subscribes the calling process to `topic`.

  The process will receive `{:pubsub_message, topic, message}` tuples for
  each subsequent broadcast on this topic.
  """
  @spec subscribe(topic()) :: :ok | {:error, term()}
  def subscribe(topic) when is_binary(topic) do
    case Registry.register(@registry, topic, nil) do
      {:ok, _pid} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Removes the calling process's subscription from `topic`."
  @spec unsubscribe(topic()) :: :ok
  def unsubscribe(topic) when is_binary(topic) do
    Registry.unregister(@registry, topic)
  end

  @doc """
  Sends `message` to all processes subscribed to `topic`.

  Returns the number of processes the message was dispatched to.
  """
  @spec broadcast(topic(), message()) :: non_neg_integer()
  def broadcast(topic, message) when is_binary(topic) do
    @registry
    |> Registry.lookup(topic)
    |> Enum.reduce(0, fn {pid, _}, count ->
      send(pid, {@message_tag, topic, message})
      count + 1
    end)
  end

  @doc """
  Delivers `message` to `recipient_pid` only if it is subscribed to `topic`.

  Returns `{:error, :not_subscribed}` when the pid has no matching subscription.
  """
  @spec send_to(topic(), pid(), message()) :: :ok | {:error, :not_subscribed}
  def send_to(topic, recipient_pid, message)
      when is_binary(topic) and is_pid(recipient_pid) do
    subscribed =
      @registry
      |> Registry.lookup(topic)
      |> Enum.any?(fn {pid, _} -> pid == recipient_pid end)

    if subscribed do
      send(recipient_pid, {@message_tag, topic, message})
      :ok
    else
      {:error, :not_subscribed}
    end
  end

  @doc "Returns the number of active subscribers for `topic`."
  @spec subscriber_count(topic()) :: non_neg_integer()
  def subscriber_count(topic) when is_binary(topic) do
    topic
    |> then(&Registry.lookup(@registry, &1))
    |> length()
  end

  @doc "Lists all topics that currently have at least one subscriber."
  @spec active_topics() :: [topic()]
  def active_topics do
    @registry
    |> Registry.select([{{:"$1", :_, :_}, [], [:"$1"]}])
    |> Enum.uniq()
    |> Enum.sort()
  end
end
```
