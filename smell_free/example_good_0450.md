```elixir
defmodule MyApp.Comms.MessageBroker do
  @moduledoc """
  A supervised GenServer acting as an in-process message broker for
  fan-out delivery to registered named channels. Channels subscribe by
  name and receive messages as `{:message, channel_name, payload}`
  tuples. The broker is suitable for low-latency intra-node pub/sub
  where Phoenix.PubSub cluster overhead is unnecessary.

  Channels are tracked by name rather than pid so that re-registering
  after a crash replaces the stale entry automatically.
  """

  use GenServer

  require Logger

  @type channel_name :: String.t()
  @type payload :: term()

  @doc "Starts the message broker."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Subscribes the calling process to `channel_name`. Overwrites any
  previous subscription under the same name.
  """
  @spec subscribe(channel_name()) :: :ok
  def subscribe(channel_name) when is_binary(channel_name) do
    GenServer.call(__MODULE__, {:subscribe, channel_name, self()})
  end

  @doc "Removes the subscription for `channel_name`."
  @spec unsubscribe(channel_name()) :: :ok
  def unsubscribe(channel_name) when is_binary(channel_name) do
    GenServer.cast(__MODULE__, {:unsubscribe, channel_name})
  end

  @doc """
  Publishes `payload` to `channel_name`. Returns `:ok` whether or not
  a subscriber exists; undeliverable messages are silently dropped.
  """
  @spec publish(channel_name(), payload()) :: :ok
  def publish(channel_name, payload) when is_binary(channel_name) do
    GenServer.cast(__MODULE__, {:publish, channel_name, payload})
  end

  @doc """
  Broadcasts `payload` to all currently subscribed channels.
  """
  @spec broadcast(payload()) :: :ok
  def broadcast(payload) do
    GenServer.cast(__MODULE__, {:broadcast, payload})
  end

  @doc "Returns the list of currently subscribed channel names."
  @spec subscribed_channels() :: [channel_name()]
  def subscribed_channels do
    GenServer.call(__MODULE__, :subscribed_channels)
  end

  @impl GenServer
  def init(_opts) do
    {:ok, %{subscribers: %{}, monitors: %{}}}
  end

  @impl GenServer
  def handle_call({:subscribe, name, pid}, _from, state) do
    ref = Process.monitor(pid)
    old_ref = Map.get(state.monitors, name)
    if old_ref, do: Process.demonitor(old_ref, [:flush])

    new_state = %{
      state
      | subscribers: Map.put(state.subscribers, name, pid),
        monitors: Map.put(state.monitors, name, ref)
    }

    {:reply, :ok, new_state}
  end

  @impl GenServer
  def handle_call(:subscribed_channels, _from, state) do
    {:reply, Map.keys(state.subscribers), state}
  end

  @impl GenServer
  def handle_cast({:unsubscribe, name}, state) do
    if ref = Map.get(state.monitors, name), do: Process.demonitor(ref, [:flush])

    new_state = %{
      state
      | subscribers: Map.delete(state.subscribers, name),
        monitors: Map.delete(state.monitors, name)
    }

    {:noreply, new_state}
  end

  @impl GenServer
  def handle_cast({:publish, name, payload}, state) do
    case Map.get(state.subscribers, name) do
      nil -> :ok
      pid -> send(pid, {:message, name, payload})
    end

    {:noreply, state}
  end

  @impl GenServer
  def handle_cast({:broadcast, payload}, state) do
    Enum.each(state.subscribers, fn {name, pid} ->
      send(pid, {:message, name, payload})
    end)

    {:noreply, state}
  end

  @impl GenServer
  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    name =
      Enum.find_value(state.monitors, fn {n, r} -> if r == ref, do: n end)

    new_state =
      if name do
        %{
          state
          | subscribers: Map.delete(state.subscribers, name),
            monitors: Map.delete(state.monitors, name)
        }
      else
        state
      end

    {:noreply, new_state}
  end
end
```
