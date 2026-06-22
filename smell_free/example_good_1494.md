```elixir
defmodule Events.Bus do
  @moduledoc """
  Lightweight in-process event bus backed by `Registry` for pub/sub between OTP processes.
  Handlers subscribe to named topics and receive events as plain messages.
  """

  @registry Events.Bus.Registry

  @type topic :: String.t()
  @type event :: %{topic: topic(), payload: map(), emitted_at: DateTime.t()}

  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(_opts) do
    %{
      id: __MODULE__,
      start: {Registry, :start_link, [[keys: :duplicate, name: @registry]]},
      type: :worker
    }
  end

  @spec subscribe(topic()) :: {:ok, {topic(), pid()}} | {:error, term()}
  def subscribe(topic) when is_binary(topic) do
    case Registry.register(@registry, topic, self()) do
      {:ok, _} -> {:ok, {topic, self()}}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec unsubscribe(topic()) :: :ok
  def unsubscribe(topic) when is_binary(topic) do
    Registry.unregister(@registry, topic)
  end

  @spec publish(topic(), map()) :: :ok
  def publish(topic, payload) when is_binary(topic) and is_map(payload) do
    event = build_event(topic, payload)

    Registry.dispatch(@registry, topic, fn entries ->
      Enum.each(entries, fn {pid, _} -> send(pid, {:event, event}) end)
    end)
  end

  @spec subscriber_count(topic()) :: non_neg_integer()
  def subscriber_count(topic) when is_binary(topic) do
    Registry.count_match(@registry, topic, :_)
  end

  @spec build_event(topic(), map()) :: event()
  defp build_event(topic, payload) do
    %{topic: topic, payload: payload, emitted_at: DateTime.utc_now()}
  end
end

defmodule Events.AuditLogger do
  @moduledoc """
  GenServer that subscribes to the events bus and persists audit log entries
  for all events matching a configurable topic prefix.
  """

  use GenServer

  alias Events.Bus

  @type state :: %{topic_prefix: String.t(), log: [Bus.event()]}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec recent_entries(pos_integer()) :: [Bus.event()]
  def recent_entries(limit) when is_integer(limit) and limit > 0 do
    GenServer.call(__MODULE__, {:recent, limit})
  end

  @spec entry_count() :: non_neg_integer()
  def entry_count do
    GenServer.call(__MODULE__, :count)
  end

  @impl GenServer
  def init(opts) do
    topic = Keyword.get(opts, :topic, "audit.*")
    Bus.subscribe(topic)
    {:ok, %{topic_prefix: topic, log: []}}
  end

  @impl GenServer
  def handle_info({:event, event}, state) do
    {:noreply, %{state | log: [event | state.log]}}
  end

  @impl GenServer
  def handle_call({:recent, limit}, _from, state) do
    {:reply, Enum.take(state.log, limit), state}
  end

  def handle_call(:count, _from, state) do
    {:reply, length(state.log), state}
  end
end
```
