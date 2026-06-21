```elixir
defmodule Messaging.Message do
  @moduledoc false

  @type t :: %__MODULE__{
          id: String.t(),
          topic: String.t(),
          payload: map(),
          attempts: non_neg_integer(),
          last_error: term() | nil,
          enqueued_at: DateTime.t()
        }

  defstruct [:id, :topic, :payload, :last_error, :enqueued_at, attempts: 0]

  @spec new(String.t(), map()) :: t()
  def new(topic, payload) when is_binary(topic) and is_map(payload) do
    %__MODULE__{
      id: :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower),
      topic: topic,
      payload: payload,
      enqueued_at: DateTime.utc_now()
    }
  end

  @spec increment_attempts(t(), term()) :: t()
  def increment_attempts(%__MODULE__{} = msg, reason) do
    %{msg | attempts: msg.attempts + 1, last_error: reason}
  end
end

defmodule Messaging.DeadLetterQueue do
  @moduledoc """
  Captures messages that have exceeded their per-topic retry budget.

  Each call to `record_failure/2` increments the attempt counter for the
  given message and returns `{:ok, :retryable}` until the threshold is
  reached, at which point the message is interned in the dead-letter store
  and `{:ok, :dead_lettered}` is returned. Dead-lettered messages can be
  inspected, replayed, or purged by an operator.
  """

  use GenServer

  require Logger

  alias Messaging.Message

  @default_max_attempts 5

  @type stats :: %{
          dead_letter_count: non_neg_integer(),
          topics: %{String.t() => non_neg_integer()}
        }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec record_failure(Message.t(), term()) ::
          {:ok, :retryable} | {:ok, :dead_lettered}
  def record_failure(%Message{} = message, reason) do
    GenServer.call(__MODULE__, {:record_failure, message, reason})
  end

  @spec dead_letters(String.t() | :all) :: [Message.t()]
  def dead_letters(topic \\ :all) do
    GenServer.call(__MODULE__, {:dead_letters, topic})
  end

  @spec purge(String.t()) :: :ok | {:error, :not_found}
  def purge(message_id) when is_binary(message_id) do
    GenServer.call(__MODULE__, {:purge, message_id})
  end

  @spec stats() :: stats()
  def stats, do: GenServer.call(__MODULE__, :stats)

  @impl GenServer
  def init(opts) do
    {:ok,
     %{
       store: %{},
       max_attempts: Keyword.get(opts, :max_attempts, @default_max_attempts)
     }}
  end

  @impl GenServer
  def handle_call({:record_failure, message, reason}, _from, state) do
    updated = Message.increment_attempts(message, reason)

    if updated.attempts >= state.max_attempts do
      Logger.warning("Message dead-lettered",
        message_id: message.id,
        topic: message.topic,
        attempts: updated.attempts
      )

      {:reply, {:ok, :dead_lettered}, %{state | store: Map.put(state.store, message.id, updated)}}
    else
      {:reply, {:ok, :retryable}, state}
    end
  end

  def handle_call({:dead_letters, :all}, _from, state) do
    {:reply, Map.values(state.store), state}
  end

  def handle_call({:dead_letters, topic}, _from, state) do
    messages = state.store |> Map.values() |> Enum.filter(&(&1.topic == topic))
    {:reply, messages, state}
  end

  def handle_call({:purge, id}, _from, state) do
    case Map.fetch(state.store, id) do
      {:ok, _} -> {:reply, :ok, %{state | store: Map.delete(state.store, id)}}
      :error -> {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call(:stats, _from, state) do
    topic_counts =
      Enum.reduce(state.store, %{}, fn {_id, msg}, acc ->
        Map.update(acc, msg.topic, 1, &(&1 + 1))
      end)

    {:reply, %{dead_letter_count: map_size(state.store), topics: topic_counts}, state}
  end
end
```
