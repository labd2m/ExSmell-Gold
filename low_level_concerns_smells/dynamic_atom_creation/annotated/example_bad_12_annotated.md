# Annotated Example — Dynamic Atom Creation

| Field | Value |
|---|---|
| **Smell name** | Dynamic atom creation |
| **Expected smell location** | `EventBus.subscribe/2` and `EventBus.publish/2`, lines where `String.to_atom/1` converts the topic string |
| **Affected function(s)** | `EventBus.subscribe/2`, `EventBus.publish/2` |
| **Short explanation** | Topics are provided by callers as strings and converted to atoms before being used as keys in the subscriber registry. Because any module in the application can publish or subscribe to any string topic, the number of distinct topic atoms is bounded only by how many unique strings callers choose to pass at runtime. |

```elixir
defmodule MyApp.EventBus do
  @moduledoc """
  A lightweight in-process pub/sub event bus backed by a GenServer.
  Callers subscribe to named topics and receive messages when events
  are published to those topics.
  """

  use GenServer

  require Logger

  @type topic :: String.t()
  @type handler :: (map() -> any())

  @name __MODULE__

  # ── Public API ────────────────────────────────────────────────────────────────

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, %{}, Keyword.put(opts, :name, @name))
  end

  @doc """
  Subscribes the calling process to the given topic string.
  The handler function is called with each published event map.
  """
  # VALIDATION: SMELL START - Dynamic atom creation
  # VALIDATION: This is a smell because `String.to_atom/1` is called with a topic
  # string that any caller in the application can supply. Topics are arbitrary user-
  # or developer-chosen strings (e.g., "orders.created", "users.v2.deactivated").
  # As the application evolves, new topics are added freely. Every unique topic
  # string becomes a permanent atom. In a long-running system—or one where topics
  # are constructed dynamically from runtime data—this grows without bound.
  @spec subscribe(topic(), handler()) :: :ok
  def subscribe(topic, handler) when is_binary(topic) and is_function(handler, 1) do
    topic_atom = String.to_atom(topic)
    GenServer.call(@name, {:subscribe, topic_atom, self(), handler})
  end
  # VALIDATION: SMELL END

  @doc """
  Publishes an event map to all subscribers of the given topic.
  """
  @spec publish(topic(), map()) :: :ok
  def publish(topic, event) when is_binary(topic) and is_map(event) do
    topic_atom = String.to_atom(topic)
    GenServer.cast(@name, {:publish, topic_atom, event})
  end

  @doc """
  Removes all subscriptions for the calling process on the given topic.
  """
  @spec unsubscribe(topic()) :: :ok
  def unsubscribe(topic) when is_binary(topic) do
    topic_atom = String.to_atom(topic)
    GenServer.call(@name, {:unsubscribe, topic_atom, self()})
  end

  @doc """
  Returns a list of currently registered topics.
  """
  @spec topics() :: [atom()]
  def topics do
    GenServer.call(@name, :topics)
  end

  # ── GenServer callbacks ───────────────────────────────────────────────────────

  @impl GenServer
  def init(_args) do
    {:ok, %{subscribers: %{}}}
  end

  @impl GenServer
  def handle_call({:subscribe, topic, pid, handler}, _from, state) do
    entry = {pid, handler, Process.monitor(pid)}
    updated = Map.update(state.subscribers, topic, [entry], &[entry | &1])
    {:reply, :ok, %{state | subscribers: updated}}
  end

  @impl GenServer
  def handle_call({:unsubscribe, topic, pid}, _from, state) do
    updated =
      Map.update(state.subscribers, topic, [], fn entries ->
        Enum.reject(entries, fn {p, _, ref} ->
          if p == pid, do: Process.demonitor(ref, [:flush])
          p == pid
        end)
      end)

    {:reply, :ok, %{state | subscribers: updated}}
  end

  @impl GenServer
  def handle_call(:topics, _from, state) do
    {:reply, Map.keys(state.subscribers), state}
  end

  @impl GenServer
  def handle_cast({:publish, topic, event}, state) do
    subscribers = Map.get(state.subscribers, topic, [])

    Enum.each(subscribers, fn {_pid, handler, _ref} ->
      try do
        handler.(event)
      rescue
        e -> Logger.error("EventBus handler raised", topic: topic, error: Exception.message(e))
      end
    end)

    {:noreply, state}
  end

  @impl GenServer
  def handle_info({:DOWN, ref, :process, pid, _reason}, state) do
    updated =
      Map.new(state.subscribers, fn {topic, entries} ->
        {topic, Enum.reject(entries, fn {p, _, r} -> p == pid && r == ref end)}
      end)

    {:noreply, %{state | subscribers: updated}}
  end
end
```
