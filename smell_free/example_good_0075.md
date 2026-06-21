```elixir
defmodule Events.Router do
  @moduledoc """
  Namespaced publish/subscribe event bus built on Phoenix.PubSub.

  Topics are prefixed with a domain atom to prevent subscriber collision
  across bounded contexts. Publishers broadcast typed event structs rather
  than raw maps, giving subscribers compile-time visibility of the schema.
  """

  @type domain :: atom()
  @type topic :: String.t()

  @spec subscribe(domain(), topic()) :: :ok | {:error, term()}
  def subscribe(domain, topic) when is_atom(domain) and is_binary(topic) do
    Phoenix.PubSub.subscribe(pubsub(), namespaced(domain, topic))
  end

  @spec unsubscribe(domain(), topic()) :: :ok
  def unsubscribe(domain, topic) when is_atom(domain) and is_binary(topic) do
    Phoenix.PubSub.unsubscribe(pubsub(), namespaced(domain, topic))
  end

  @spec broadcast(domain(), topic(), term()) :: :ok | {:error, term()}
  def broadcast(domain, topic, event) when is_atom(domain) and is_binary(topic) do
    Phoenix.PubSub.broadcast(pubsub(), namespaced(domain, topic), {:event, event})
  end

  @spec local_broadcast(domain(), topic(), term()) :: :ok
  def local_broadcast(domain, topic, event) when is_atom(domain) and is_binary(topic) do
    Phoenix.PubSub.local_broadcast(pubsub(), namespaced(domain, topic), {:event, event})
  end

  defp namespaced(domain, topic), do: "#{domain}:#{topic}"

  defp pubsub, do: Application.fetch_env!(:my_app, :pubsub_name)
end

defmodule Events.Subscriber do
  @moduledoc """
  Behaviour and `use` macro for building supervised event subscriber processes.

  A module that uses this behaviour declares `:domain` and `:topic` at
  compile time. The generated `GenServer` subscribes on init and dispatches
  incoming events to the `handle_event/2` callback implemented by the caller.
  """

  @callback handle_event(event :: term(), metadata :: map()) :: :ok | {:error, term()}

  defmacro __using__(opts) do
    domain = Keyword.fetch!(opts, :domain)
    topic = Keyword.fetch!(opts, :topic)

    quote do
      @behaviour Events.Subscriber

      use GenServer

      @spec start_link(keyword()) :: GenServer.on_start()
      def start_link(init_opts \\ []) do
        GenServer.start_link(__MODULE__, init_opts, name: __MODULE__)
      end

      @impl GenServer
      def init(opts) do
        :ok = Events.Router.subscribe(unquote(domain), unquote(topic))
        {:ok, opts}
      end

      @impl GenServer
      def handle_info({:event, event}, state) do
        __MODULE__.handle_event(event, %{received_at: System.system_time(:millisecond)})
        {:noreply, state}
      end

      @impl GenServer
      def handle_info(_ignored, state), do: {:noreply, state}
    end
  end
end

defmodule Orders.Projector do
  @moduledoc """
  Maintains a read-side projection of order lifecycle events.
  """

  use Events.Subscriber, domain: :orders, topic: "lifecycle"

  require Logger

  @impl Events.Subscriber
  def handle_event(%{type: :order_placed} = event, _meta) do
    Orders.ReadModel.insert(event)
    :ok
  end

  def handle_event(%{type: :order_shipped} = event, _meta) do
    Orders.ReadModel.mark_shipped(event.order_id, event.tracking_number)
    :ok
  end

  def handle_event(%{type: :order_cancelled} = event, _meta) do
    Orders.ReadModel.mark_cancelled(event.order_id, event.reason)
    :ok
  end

  def handle_event(event, _meta) do
    Logger.debug("Orders.Projector: unhandled event type", type: inspect(event[:type]))
    :ok
  end
end
```
