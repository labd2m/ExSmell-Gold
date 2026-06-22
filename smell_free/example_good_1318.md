**File:** `example_good_1318.md`

```elixir
defmodule MessageConsumer.Message do
  @moduledoc "Represents a single message consumed from a topic partition."

  @enforce_keys [:topic, :partition, :offset, :key, :value, :timestamp]
  defstruct [:topic, :partition, :offset, :key, :value, :timestamp, :headers]

  @type t :: %__MODULE__{
          topic: String.t(),
          partition: non_neg_integer(),
          offset: non_neg_integer(),
          key: binary() | nil,
          value: binary(),
          timestamp: DateTime.t(),
          headers: [{String.t(), binary()}]
        }
end

defmodule MessageConsumer.Handler do
  @moduledoc "Behaviour for processing batches of consumed messages."

  alias MessageConsumer.Message

  @doc "Processes a batch of messages. Returns :ok or {:error, reason} on failure."
  @callback handle_batch([Message.t()]) :: :ok | {:error, term()}
end

defmodule MessageConsumer.OffsetTracker do
  @moduledoc """
  Tracks the highest committed offset per topic-partition pair.
  All writes and reads go through the explicit API; no direct access to state.
  """

  use Agent

  @type partition_key :: {String.t(), non_neg_integer()}

  @spec start_link(keyword()) :: Agent.on_start()
  def start_link(opts \\ []) do
    Agent.start_link(fn -> %{} end, name: Keyword.get(opts, :name, __MODULE__))
  end

  @spec commit(String.t(), non_neg_integer(), non_neg_integer()) :: :ok
  def commit(topic, partition, offset) do
    Agent.update(__MODULE__, &Map.put(&1, {topic, partition}, offset))
  end

  @spec last_committed(String.t(), non_neg_integer()) :: non_neg_integer() | nil
  def last_committed(topic, partition) do
    Agent.get(__MODULE__, &Map.get(&1, {topic, partition}))
  end

  @spec all_offsets() :: %{partition_key() => non_neg_integer()}
  def all_offsets, do: Agent.get(__MODULE__, & &1)
end

defmodule MessageConsumer.Worker do
  @moduledoc """
  A supervised GenServer that polls a single topic partition, dispatches
  message batches to a configured handler, and commits offsets on success.
  """

  use GenServer

  require Logger

  alias MessageConsumer.{Message, OffsetTracker}

  @default_poll_interval_ms 1_000
  @default_batch_size 50

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @impl GenServer
  def init(opts) do
    state = %{
      topic: Keyword.fetch!(opts, :topic),
      partition: Keyword.fetch!(opts, :partition),
      handler: Keyword.fetch!(opts, :handler),
      poll_interval_ms: Keyword.get(opts, :poll_interval_ms, @default_poll_interval_ms),
      batch_size: Keyword.get(opts, :batch_size, @default_batch_size),
      source: Keyword.fetch!(opts, :source)
    }

    schedule_poll(state.poll_interval_ms)
    {:ok, state}
  end

  @impl GenServer
  def handle_info(:poll, state) do
    last_offset = OffsetTracker.last_committed(state.topic, state.partition)
    start_offset = if last_offset, do: last_offset + 1, else: 0

    case state.source.fetch(state.topic, state.partition, start_offset, state.batch_size) do
      {:ok, []} ->
        :ok

      {:ok, messages} ->
        process_batch(messages, state)

      {:error, reason} ->
        Logger.error("Consumer poll failed for #{state.topic}/#{state.partition}: #{inspect(reason)}")
    end

    schedule_poll(state.poll_interval_ms)
    {:noreply, state}
  end

  defp process_batch(messages, state) do
    case state.handler.handle_batch(messages) do
      :ok ->
        last = List.last(messages)
        OffsetTracker.commit(state.topic, state.partition, last.offset)
        Logger.debug("Processed #{length(messages)} messages from #{state.topic}/#{state.partition}")

      {:error, reason} ->
        Logger.error("Batch handler failed for #{state.topic}/#{state.partition}: #{inspect(reason)}")
    end
  end

  defp schedule_poll(interval_ms) do
    Process.send_after(self(), :poll, interval_ms)
  end
end

defmodule MessageConsumer.Supervisor do
  @moduledoc "Supervises one worker per assigned topic-partition."

  use Supervisor

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl Supervisor
  def init(opts) do
    assignments = Keyword.fetch!(opts, :assignments)
    handler = Keyword.fetch!(opts, :handler)
    source = Keyword.fetch!(opts, :source)

    workers =
      Enum.map(assignments, fn {topic, partition} ->
        id = "#{topic}_#{partition}"

        Supervisor.child_spec(
          {MessageConsumer.Worker,
           topic: topic, partition: partition, handler: handler, source: source},
          id: id
        )
      end)

    children = [{OffsetTracker, []} | workers]
    Supervisor.init(children, strategy: :one_for_one)
  end
end
```
