```elixir
defmodule Sse.Event do
  @moduledoc false

  @type t :: %__MODULE__{
          id: String.t() | nil,
          event: String.t() | nil,
          data: String.t(),
          retry_ms: pos_integer() | nil
        }

  defstruct [:id, :event, :data, :retry_ms]

  @spec serialize(t()) :: iodata()
  def serialize(%__MODULE__{} = event) do
    lines = []
    lines = if event.retry_ms, do: [["retry: ", Integer.to_string(event.retry_ms), "\n"] | lines], else: lines
    lines = if event.id, do: [["id: ", event.id, "\n"] | lines], else: lines
    lines = if event.event, do: [["event: ", event.event, "\n"] | lines], else: lines
    data_lines = event.data |> String.split("\n") |> Enum.map(&["data: ", &1, "\n"])
    Enum.reverse(lines) ++ data_lines ++ ["\n"]
  end
end

defmodule Sse.Broadcaster do
  @moduledoc """
  Manages SSE subscriber connections grouped by topic.
  Processes subscribe by registering their PID; the broadcaster delivers
  serialized events to all subscribers for a given topic. Subscribers
  that have disconnected are automatically purged when delivery fails.
  """

  use GenServer

  alias Sse.Event

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec subscribe(String.t(), pid()) :: :ok
  def subscribe(topic, pid \\ self()) when is_binary(topic) and is_pid(pid) do
    GenServer.call(__MODULE__, {:subscribe, topic, pid})
  end

  @spec unsubscribe(String.t(), pid()) :: :ok
  def unsubscribe(topic, pid \\ self()) when is_binary(topic) do
    GenServer.cast(__MODULE__, {:unsubscribe, topic, pid})
  end

  @spec broadcast(String.t(), Event.t()) :: :ok
  def broadcast(topic, %Event{} = event) when is_binary(topic) do
    GenServer.cast(__MODULE__, {:broadcast, topic, event})
  end

  @spec subscriber_count(String.t()) :: non_neg_integer()
  def subscriber_count(topic) when is_binary(topic) do
    GenServer.call(__MODULE__, {:count, topic})
  end

  @impl GenServer
  def init(_opts), do: {:ok, %{topics: %{}}}

  @impl GenServer
  def handle_call({:subscribe, topic, pid}, _from, state) do
    ref = Process.monitor(pid)
    subscribers = Map.get(state.topics, topic, %{})
    updated = Map.put(state.topics, topic, Map.put(subscribers, pid, ref))
    {:reply, :ok, %{state | topics: updated}}
  end

  def handle_call({:count, topic}, _from, state) do
    count = state.topics |> Map.get(topic, %{}) |> map_size()
    {:reply, count, state}
  end

  @impl GenServer
  def handle_cast({:unsubscribe, topic, pid}, state) do
    state = remove_subscriber(state, topic, pid)
    {:noreply, state}
  end

  def handle_cast({:broadcast, topic, event}, state) do
    subscribers = Map.get(state.topics, topic, %{})
    payload = Event.serialize(event)

    dead_pids =
      subscribers
      |> Map.keys()
      |> Enum.reject(fn pid ->
        try do
          send(pid, {:sse_event, payload})
          true
        rescue
          _ -> false
        end
      end)

    state = Enum.reduce(dead_pids, state, &remove_subscriber(&2, topic, &1))
    {:noreply, state}
  end

  @impl GenServer
  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    updated_topics =
      Map.new(state.topics, fn {topic, subs} -> {topic, Map.delete(subs, pid)} end)

    {:noreply, %{state | topics: updated_topics}}
  end

  defp remove_subscriber(state, topic, pid) do
    case get_in(state.topics, [topic, pid]) do
      nil -> state
      ref ->
        Process.demonitor(ref, [:flush])
        updated = update_in(state.topics, [topic], &Map.delete(&1, pid))
        updated
    end
  end
end
```
