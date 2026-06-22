```elixir
defmodule Messaging.DeadLetterQueue do
  @moduledoc """
  Supervised GenServer implementing a dead letter queue for unprocessable messages.

  Messages that fail processing after exhausting retries are deposited here
  for offline inspection and manual replay. The queue is bounded by a
  configurable maximum size; oldest entries are evicted when capacity is reached.
  """

  use GenServer

  require Logger

  @default_capacity 1_000

  @type dead_letter :: %{
          id: String.t(),
          original_topic: String.t(),
          payload: map(),
          failure_reason: String.t(),
          failed_at: DateTime.t(),
          attempt_count: pos_integer()
        }

  @doc """
  Starts the dead letter queue as a named linked process.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Deposits a message into the dead letter queue.

  If the queue is at capacity, the oldest message is evicted to make room.
  """
  @spec enqueue(String.t(), map(), String.t(), pos_integer()) :: :ok
  def enqueue(topic, payload, failure_reason, attempt_count)
      when is_binary(topic) and is_map(payload) do
    GenServer.cast(__MODULE__, {:enqueue, topic, payload, failure_reason, attempt_count})
  end

  @doc """
  Returns a paginated slice of dead letter entries, newest first.
  """
  @spec list(pos_integer(), pos_integer()) :: [dead_letter()]
  def list(limit \\ 50, offset \\ 0) when is_integer(limit) and is_integer(offset) do
    GenServer.call(__MODULE__, {:list, limit, offset})
  end

  @doc """
  Removes a specific dead letter entry by its ID.

  Returns `:ok` whether or not the entry existed.
  """
  @spec discard(String.t()) :: :ok
  def discard(id) when is_binary(id) do
    GenServer.cast(__MODULE__, {:discard, id})
  end

  @doc """
  Returns the current count of entries in the dead letter queue.
  """
  @spec size() :: non_neg_integer()
  def size do
    GenServer.call(__MODULE__, :size)
  end

  @impl GenServer
  def init(opts) do
    capacity = Keyword.get(opts, :capacity, @default_capacity)
    {:ok, %{entries: :queue.new(), count: 0, capacity: capacity}}
  end

  @impl GenServer
  def handle_cast({:enqueue, topic, payload, failure_reason, attempt_count}, state) do
    entry = build_entry(topic, payload, failure_reason, attempt_count)
    Logger.warning("[DLQ] Depositing dead letter", topic: topic, id: entry.id)

    new_state = insert_entry(state, entry)
    {:noreply, new_state}
  end

  @impl GenServer
  def handle_cast({:discard, id}, state) do
    updated_entries =
      state.entries
      |> :queue.to_list()
      |> Enum.reject(fn e -> e.id == id end)
      |> :queue.from_list()

    new_count = :queue.len(updated_entries)
    {:noreply, %{state | entries: updated_entries, count: new_count}}
  end

  @impl GenServer
  def handle_call({:list, limit, offset}, _from, state) do
    result =
      state.entries
      |> :queue.to_list()
      |> Enum.reverse()
      |> Enum.drop(offset)
      |> Enum.take(limit)

    {:reply, result, state}
  end

  @impl GenServer
  def handle_call(:size, _from, state) do
    {:reply, state.count, state}
  end

  defp insert_entry(%{count: count, capacity: capacity} = state, entry) when count >= capacity do
    {_, trimmed_queue} = :queue.out(state.entries)
    new_queue = :queue.in(entry, trimmed_queue)
    %{state | entries: new_queue}
  end

  defp insert_entry(state, entry) do
    new_queue = :queue.in(entry, state.entries)
    %{state | entries: new_queue, count: state.count + 1}
  end

  defp build_entry(topic, payload, failure_reason, attempt_count) do
    %{
      id: generate_id(),
      original_topic: topic,
      payload: payload,
      failure_reason: failure_reason,
      failed_at: DateTime.utc_now(),
      attempt_count: attempt_count
    }
  end

  defp generate_id do
    :crypto.strong_rand_bytes(12) |> Base.url_encode64(padding: false)
  end
end
```
