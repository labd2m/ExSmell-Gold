```elixir
defmodule Platform.EventBus do
  @moduledoc """
  A lightweight in-process publish/subscribe event bus backed by
  `Registry` in `:duplicate` mode. Subscribers register their interest
  in a topic and receive matching events as plain Erlang messages.
  The bus is suitable for cross-context communication within a single
  node; for cluster-wide delivery use `Phoenix.PubSub` instead.

  Topics are any term, though convention is `{domain, event_name}` tuples,
  e.g. `{:orders, :placed}` or `{:users, :email_verified}`.
  """

  @registry __MODULE__.Registry

  @type topic :: term()
  @type event :: %{
          required(:topic) => topic(),
          required(:payload) => term(),
          required(:emitted_at) => DateTime.t()
        }

  # ---------------------------------------------------------------------------
  # Supervision
  # ---------------------------------------------------------------------------

  @doc """
  Returns the child spec for the underlying Registry. Add to your
  application supervisor before any process that calls `subscribe/1`.
  """
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(_opts) do
    Registry.child_spec(keys: :duplicate, name: @registry)
  end

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @doc """
  Subscribes the calling process to `topic`. Subsequent `publish/2` calls
  for that topic will deliver messages to this process as:

      {:event, %{topic: topic, payload: payload, emitted_at: datetime}}

  Returns `{:ok, pid}` — pass the returned pid to `unsubscribe/2` to
  cleanly deregister before the process terminates.
  """
  @spec subscribe(topic()) :: {:ok, pid()}
  def subscribe(topic) do
    {:ok, _} = Registry.register(@registry, topic, [])
    {:ok, self()}
  end

  @doc """
  Removes the subscription for `pid` on `topic`.
  Safe to call even when no subscription exists.
  """
  @spec unsubscribe(topic(), pid()) :: :ok
  def unsubscribe(topic, pid \\ self()) do
    Registry.unregister_match(@registry, topic, pid)
    :ok
  end

  @doc """
  Delivers `payload` to all processes subscribed to `topic`.
  The delivery is asynchronous; callers are not blocked waiting
  for subscribers to process the message. Returns the number of
  subscribers notified.
  """
  @spec publish(topic(), term()) :: non_neg_integer()
  def publish(topic, payload) do
    event = %{topic: topic, payload: payload, emitted_at: DateTime.utc_now()}
    message = {:event, event}

    subscribers = Registry.lookup(@registry, topic)

    Enum.each(subscribers, fn {pid, _value} ->
      send(pid, message)
    end)

    length(subscribers)
  end

  @doc """
  Returns the count of current subscribers for `topic`.
  """
  @spec subscriber_count(topic()) :: non_neg_integer()
  def subscriber_count(topic) do
    @registry
    |> Registry.lookup(topic)
    |> length()
  end

  @doc """
  Returns all currently registered topics that have at least one subscriber.
  """
  @spec active_topics() :: [topic()]
  def active_topics do
    Registry.select(@registry, [{{:"$1", :_, :_}, [], [:"$1"]}])
    |> Enum.uniq()
  end
end

defmodule Platform.EventBus.Subscriber do
  @moduledoc """
  A convenience `GenServer` base for processes that need to subscribe to
  multiple `EventBus` topics and react to incoming events. Override
  `handle_event/2` to process each event without managing the subscription
  boilerplate manually.
  """

  defmacro __using__(topics: topics) do
    quote do
      use GenServer

      @topics unquote(topics)

      def init(args) do
        Enum.each(@topics, fn topic ->
          Platform.EventBus.subscribe(topic)
        end)

        {:ok, args}
      end

      def handle_info({:event, event}, state) do
        handle_event(event.topic, event.payload)
        {:noreply, state}
      end

      def handle_event(_topic, _payload), do: :ok

      defoverridable handle_event: 2
    end
  end
end
```
