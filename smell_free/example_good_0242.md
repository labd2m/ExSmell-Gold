# File: `example_good_242.md`

```elixir
defmodule Events.ReplayBuffer do
  @moduledoc """
  GenServer that retains a bounded, ordered window of recent domain events
  for late-joining subscribers to replay on connection.

  Events are stored in a circular buffer. Consumers can request all events
  since a given sequence number, making this suitable for WebSocket
  reconnection flows or in-process fan-out with catch-up semantics.
  """

  use GenServer

  @default_capacity 5_000

  @type event_type :: atom()
  @type sequence :: pos_integer()

  @type event_envelope :: %{
          seq: sequence(),
          type: event_type(),
          payload: map(),
          occurred_at: DateTime.t()
        }

  @type opts :: [capacity: pos_integer()]

  @doc false
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Appends an event to the buffer. The buffer assigns a monotonic sequence
  number and returns it.

  Returns `{:ok, sequence}`.
  """
  @spec append(event_type(), map()) :: {:ok, sequence()}
  def append(type, payload) when is_atom(type) and is_map(payload) do
    GenServer.call(__MODULE__, {:append, type, payload})
  end

  @doc """
  Returns all events with a sequence number strictly greater than `after_seq`.

  Returns at most the buffer's current capacity. When `after_seq` is `0`,
  all buffered events are returned.
  """
  @spec since(sequence()) :: [event_envelope()]
  def since(after_seq) when is_integer(after_seq) and after_seq >= 0 do
    GenServer.call(__MODULE__, {:since, after_seq})
  end

  @doc """
  Returns the highest sequence number currently in the buffer, or `0`
  if the buffer is empty.
  """
  @spec head_sequence() :: non_neg_integer()
  def head_sequence do
    GenServer.call(__MODULE__, :head_sequence)
  end

  @doc """
  Returns the count of events currently retained in the buffer.
  """
  @spec size() :: non_neg_integer()
  def size do
    GenServer.call(__MODULE__, :size)
  end

  @doc """
  Clears all buffered events and resets the sequence counter.
  """
  @spec flush() :: :ok
  def flush do
    GenServer.cast(__MODULE__, :flush)
  end

  @impl GenServer
  def init(opts) do
    capacity = Keyword.get(opts, :capacity, @default_capacity)
    {:ok, %{events: :queue.new(), count: 0, capacity: capacity, next_seq: 1}}
  end

  @impl GenServer
  def handle_call({:append, type, payload}, _from, state) do
    seq = state.next_seq
    envelope = %{seq: seq, type: type, payload: payload, occurred_at: DateTime.utc_now()}
    {new_queue, new_count} = insert_evicting(state.events, state.count, state.capacity, envelope)
    {:reply, {:ok, seq}, %{state | events: new_queue, count: new_count, next_seq: seq + 1}}
  end

  @impl GenServer
  def handle_call({:since, after_seq}, _from, state) do
    matching =
      state.events
      |> :queue.to_list()
      |> Enum.filter(&(&1.seq > after_seq))

    {:reply, matching, state}
  end

  @impl GenServer
  def handle_call(:head_sequence, _from, %{next_seq: 1} = state) do
    {:reply, 0, state}
  end

  @impl GenServer
  def handle_call(:head_sequence, _from, state) do
    {:reply, state.next_seq - 1, state}
  end

  @impl GenServer
  def handle_call(:size, _from, state) do
    {:reply, state.count, state}
  end

  @impl GenServer
  def handle_cast(:flush, state) do
    {:noreply, %{state | events: :queue.new(), count: 0, next_seq: 1}}
  end

  defp insert_evicting(queue, count, capacity, envelope) when count < capacity do
    {:queue.in(envelope, queue), count + 1}
  end

  defp insert_evicting(queue, count, _capacity, envelope) do
    {_dropped, trimmed} = :queue.out(queue)
    {:queue.in(envelope, trimmed), count}
  end
end
```
