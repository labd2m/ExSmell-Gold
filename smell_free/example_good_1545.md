```elixir
defmodule Streaming.EventBroadcaster do
  @moduledoc """
  PubSub-backed event broadcaster for real-time domain event fan-out.

  Provides a structured interface for publishing domain events and managing
  topic subscriptions. All topic names are namespaced under the application
  prefix to prevent cross-application collisions on a shared PubSub bus.
  """

  @pubsub_server Streaming.PubSub
  @topic_prefix "streaming"

  @type topic :: String.t()
  @type domain_event :: %{
          type: atom(),
          payload: map(),
          occurred_at: DateTime.t(),
          correlation_id: String.t()
        }

  @doc """
  Publishes a domain event to all subscribers of the given topic.
  """
  @spec broadcast(topic(), domain_event()) :: :ok | {:error, term()}
  def broadcast(topic, event) when is_binary(topic) and is_map(event) do
    Phoenix.PubSub.broadcast(@pubsub_server, namespaced_topic(topic), {:domain_event, event})
  end

  @doc """
  Subscribes the calling process to the given topic.

  Subsequent events broadcast to this topic will arrive as
  `{:domain_event, event}` messages.
  """
  @spec subscribe(topic()) :: :ok | {:error, term()}
  def subscribe(topic) when is_binary(topic) do
    Phoenix.PubSub.subscribe(@pubsub_server, namespaced_topic(topic))
  end

  @doc """
  Unsubscribes the calling process from the given topic.
  """
  @spec unsubscribe(topic()) :: :ok
  def unsubscribe(topic) when is_binary(topic) do
    Phoenix.PubSub.unsubscribe(@pubsub_server, namespaced_topic(topic))
  end

  @doc """
  Builds a well-formed domain event map with a generated correlation ID.
  """
  @spec build_event(atom(), map()) :: domain_event()
  def build_event(type, payload) when is_atom(type) and is_map(payload) do
    %{
      type: type,
      payload: payload,
      occurred_at: DateTime.utc_now(),
      correlation_id: generate_correlation_id()
    }
  end

  defp namespaced_topic(topic), do: "#{@topic_prefix}:#{topic}"

  defp generate_correlation_id do
    :crypto.strong_rand_bytes(16) |> Base.url_encode64(padding: false)
  end
end

defmodule Streaming.EventConsumer do
  @moduledoc """
  GenServer base for consuming domain events from the broadcaster.

  Implementing modules define `handle_event/2` to process events dispatched
  to their subscribed topics. The consumer subscribes at startup and
  unsubscribes cleanly on termination.
  """

  defmacro __using__(opts) do
    topics = Keyword.fetch!(opts, :topics)

    quote do
      use GenServer

      alias Streaming.EventBroadcaster

      @topics unquote(topics)

      def start_link(init_args \\ []) do
        GenServer.start_link(__MODULE__, init_args)
      end

      @impl GenServer
      def init(init_args) do
        Enum.each(@topics, &EventBroadcaster.subscribe/1)
        {:ok, init_args}
      end

      @impl GenServer
      def handle_info({:domain_event, event}, state) do
        new_state = handle_event(event, state)
        {:noreply, new_state}
      end

      @impl GenServer
      def terminate(_reason, _state) do
        Enum.each(@topics, &EventBroadcaster.unsubscribe/1)
        :ok
      end

      def handle_event(_event, state), do: state

      defoverridable handle_event: 2
    end
  end
end
```
