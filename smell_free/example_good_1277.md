```elixir
defmodule Events.PubSub do
  @moduledoc """
  Lightweight publish-subscribe system backed by a partitioned Registry.
  Subscribers receive `{:event, topic, message}` messages in their own process.
  """

  @registry Events.PubSub.Registry

  @type topic :: String.t()
  @type message :: term()

  @spec subscribe(topic()) :: :ok | {:error, {:already_registered, pid()}}
  def subscribe(topic) when is_binary(topic) do
    case Registry.register(@registry, topic, nil) do
      {:ok, _} -> :ok
      {:error, {:already_registered, _pid}} = err -> err
    end
  end

  @spec unsubscribe(topic()) :: :ok
  def unsubscribe(topic) when is_binary(topic) do
    Registry.unregister(@registry, topic)
    :ok
  end

  @spec publish(topic(), message()) :: :ok
  def publish(topic, message) when is_binary(topic) do
    Registry.dispatch(@registry, topic, fn entries ->
      Enum.each(entries, fn {pid, _} -> send(pid, {:event, topic, message}) end)
    end)
  end

  @spec subscriber_count(topic()) :: non_neg_integer()
  def subscriber_count(topic) when is_binary(topic) do
    Registry.count_match(@registry, topic, :_)
  end
end

defmodule Events.BaseSubscriber do
  @moduledoc """
  A generic GenServer-based subscriber. Derive with `use Events.BaseSubscriber`
  and implement the `c:handle_event/3` callback to process inbound messages.
  """

  @callback handle_event(topic :: String.t(), message :: term(), state :: term()) ::
              {:ok, term()} | {:error, term()}

  defmacro __using__(_opts) do
    quote do
      use GenServer
      @behaviour Events.BaseSubscriber

      @spec start_link(keyword()) :: GenServer.on_start()
      def start_link(opts \\ []) do
        GenServer.start_link(__MODULE__, opts)
      end

      @spec subscribe(pid(), String.t()) :: :ok | {:error, term()}
      def subscribe(pid, topic) when is_binary(topic) do
        GenServer.call(pid, {:subscribe, topic})
      end

      @spec unsubscribe(pid(), String.t()) :: :ok
      def unsubscribe(pid, topic) when is_binary(topic) do
        GenServer.call(pid, {:unsubscribe, topic})
      end

      @impl GenServer
      def init(opts) do
        {:ok, %{topics: [], inner: opts}}
      end

      @impl GenServer
      def handle_call({:subscribe, topic}, _from, state) do
        case Events.PubSub.subscribe(topic) do
          :ok -> {:reply, :ok, %{state | topics: [topic | state.topics]}}
          err -> {:reply, err, state}
        end
      end

      def handle_call({:unsubscribe, topic}, _from, state) do
        Events.PubSub.unsubscribe(topic)
        {:reply, :ok, %{state | topics: List.delete(state.topics, topic)}}
      end

      @impl GenServer
      def handle_info({:event, topic, message}, state) do
        case handle_event(topic, message, state.inner) do
          {:ok, new_inner} -> {:noreply, %{state | inner: new_inner}}
          {:error, _} -> {:noreply, state}
        end
      end
    end
  end
end
```
