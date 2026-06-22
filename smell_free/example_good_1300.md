**File:** `example_good_1300.md`

```elixir
defmodule PubSub.Subscription do
  @moduledoc "Represents a single topic subscription held by a subscriber process."

  @enforce_keys [:topic, :subscriber_pid, :ref]
  defstruct [:topic, :subscriber_pid, :ref, :metadata]

  @type t :: %__MODULE__{
          topic: String.t(),
          subscriber_pid: pid(),
          ref: reference(),
          metadata: map() | nil
        }
end

defmodule PubSub.Message do
  @moduledoc "Represents a message published to a topic."

  @enforce_keys [:topic, :payload, :published_at]
  defstruct [:topic, :payload, :published_at, :publisher_pid]

  @type t :: %__MODULE__{
          topic: String.t(),
          payload: term(),
          published_at: DateTime.t(),
          publisher_pid: pid() | nil
        }
end

defmodule PubSub.Broker do
  @moduledoc """
  A GenServer that manages topic subscriptions and dispatches published
  messages to all live subscribers. Dead subscribers are cleaned up
  automatically via process monitoring.
  """

  use GenServer

  require Logger

  alias PubSub.{Message, Subscription}

  @type state :: %{
          subscriptions: %{String.t() => [Subscription.t()]},
          monitors: %{reference() => {String.t(), pid()}}
        }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @spec subscribe(String.t(), pid()) :: {:ok, Subscription.t()}
  def subscribe(topic, pid \\ self()) when is_binary(topic) and is_pid(pid) do
    GenServer.call(__MODULE__, {:subscribe, topic, pid})
  end

  @spec unsubscribe(reference()) :: :ok
  def unsubscribe(ref) when is_reference(ref) do
    GenServer.call(__MODULE__, {:unsubscribe, ref})
  end

  @spec publish(String.t(), term()) :: :ok
  def publish(topic, payload) when is_binary(topic) do
    GenServer.cast(__MODULE__, {:publish, topic, payload, self()})
  end

  @spec subscribers(String.t()) :: [pid()]
  def subscribers(topic) when is_binary(topic) do
    GenServer.call(__MODULE__, {:subscribers, topic})
  end

  @impl GenServer
  def init(_opts) do
    {:ok, %{subscriptions: %{}, monitors: %{}}}
  end

  @impl GenServer
  def handle_call({:subscribe, topic, pid}, _from, state) do
    ref = Process.monitor(pid)

    sub = %Subscription{
      topic: topic,
      subscriber_pid: pid,
      ref: ref
    }

    updated_subs = Map.update(state.subscriptions, topic, [sub], &[sub | &1])
    updated_monitors = Map.put(state.monitors, ref, {topic, pid})

    {:reply, {:ok, sub}, %{state | subscriptions: updated_subs, monitors: updated_monitors}}
  end

  def handle_call({:unsubscribe, ref}, _from, state) do
    new_state = remove_subscription(state, ref)
    {:reply, :ok, new_state}
  end

  def handle_call({:subscribers, topic}, _from, state) do
    pids =
      state.subscriptions
      |> Map.get(topic, [])
      |> Enum.map(& &1.subscriber_pid)

    {:reply, pids, state}
  end

  @impl GenServer
  def handle_cast({:publish, topic, payload, publisher_pid}, state) do
    message = %Message{
      topic: topic,
      payload: payload,
      published_at: DateTime.utc_now(),
      publisher_pid: publisher_pid
    }

    state.subscriptions
    |> Map.get(topic, [])
    |> Enum.each(fn sub ->
      send(sub.subscriber_pid, {:pubsub_message, message})
    end)

    {:noreply, state}
  end

  @impl GenServer
  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    new_state = remove_subscription(state, ref)
    {:noreply, new_state}
  end

  defp remove_subscription(%{subscriptions: subs, monitors: monitors} = state, ref) do
    case Map.pop(monitors, ref) do
      {{topic, _pid}, updated_monitors} ->
        Process.demonitor(ref, [:flush])

        updated_subs =
          Map.update(subs, topic, [], fn list ->
            Enum.reject(list, &(&1.ref == ref))
          end)

        %{state | subscriptions: updated_subs, monitors: updated_monitors}

      {nil, _monitors} ->
        state
    end
  end
end
```
