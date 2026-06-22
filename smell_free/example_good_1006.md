```elixir
defmodule MyApp.Platform.EventBus do
  @moduledoc """
  A strongly-typed internal event bus that wraps Phoenix.PubSub with
  explicit topic contracts. Each event module declares its own topic
  via the `@topic` attribute; callers interact only through the
  `EventBus` API and never construct topic strings directly, preventing
  topic name typos and making all pub/sub relationships discoverable.
  """

  alias Phoenix.PubSub

  @pubsub MyApp.PubSub

  @doc """
  Publishes `event` to its declared topic. The topic is derived from
  the event struct's module attribute at runtime.
  """
  @spec publish(struct()) :: :ok | {:error, term()}
  def publish(%module{} = event) do
    topic = topic_for(module)
    PubSub.broadcast(@pubsub, topic, {:event, event})
  end

  @doc """
  Publishes `event` to its declared topic from within a local node
  only, bypassing cluster-wide broadcast.
  """
  @spec publish_local(struct()) :: :ok | {:error, term()}
  def publish_local(%module{} = event) do
    topic = topic_for(module)
    PubSub.local_broadcast(@pubsub, topic, {:event, event})
  end

  @doc """
  Subscribes the calling process to all events of the given `event_module`.
  Received messages arrive as `{:event, %EventModule{}}` tuples.
  """
  @spec subscribe(module()) :: :ok | {:error, term()}
  def subscribe(event_module) when is_atom(event_module) do
    PubSub.subscribe(@pubsub, topic_for(event_module))
  end

  @doc "Unsubscribes the calling process from `event_module` events."
  @spec unsubscribe(module()) :: :ok
  def unsubscribe(event_module) when is_atom(event_module) do
    PubSub.unsubscribe(@pubsub, topic_for(event_module))
  end

  @doc "Returns the PubSub topic string for `event_module`."
  @spec topic_for(module()) :: String.t()
  def topic_for(event_module) do
    if function_exported?(event_module, :__topic__, 0) do
      event_module.__topic__()
    else
      event_module
      |> Module.split()
      |> Enum.join(".")
      |> String.downcase()
    end
  end

  @doc """
  Defines the `__topic__/0` callback and `t()` type in the calling
  module, optionally overriding the default topic derivation.

  Usage:

      defmodule MyApp.Events.UserSignedUp do
        use MyApp.Platform.EventBus.Event, topic: "users.signed_up"
        defstruct [:user_id, :occurred_at]
      end
  """
  defmodule Event do
    @moduledoc false

    defmacro __using__(opts) do
      topic = Keyword.get(opts, :topic)

      quote do
        @topic unquote(topic) || __MODULE__ |> Module.split() |> Enum.join(".") |> String.downcase()

        def __topic__, do: @topic
      end
    end
  end
end
```
