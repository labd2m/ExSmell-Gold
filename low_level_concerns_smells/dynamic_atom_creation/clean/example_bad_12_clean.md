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
  @spec subscribe(topic(), handler()) :: :ok
  def subscribe(topic, handler) when is_binary(topic) and is_function(handler, 1) do
    topic_atom = String.to_atom(topic)
    GenServer.call(@name, {:subscribe, topic_atom, self(), handler})
  end

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
