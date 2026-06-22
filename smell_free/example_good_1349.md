```elixir
defmodule DeadLetter.Message do
  @moduledoc """
  Represents a failed message captured for dead-letter processing.
  Preserves the original payload, failure reason, and retry history
  for inspection, reprocessing, or alerting.
  """

  @enforce_keys [:id, :queue, :payload, :failure_reason, :failed_at]
  defstruct [:id, :queue, :payload, :failure_reason, :failed_at, :original_id,
             retry_count: 0, last_retry_at: nil]

  @type t :: %__MODULE__{
          id: String.t(),
          queue: String.t(),
          payload: map(),
          failure_reason: term(),
          failed_at: DateTime.t(),
          original_id: String.t() | nil,
          retry_count: non_neg_integer(),
          last_retry_at: DateTime.t() | nil
        }

  @spec new(String.t(), map(), term(), keyword()) :: t()
  def new(queue, payload, failure_reason, opts \\ [])
      when is_binary(queue) and is_map(payload) do
    %__MODULE__{
      id: generate_id(),
      queue: queue,
      payload: payload,
      failure_reason: failure_reason,
      failed_at: DateTime.utc_now(),
      original_id: Keyword.get(opts, :original_id),
      retry_count: 0
    }
  end

  @spec record_retry(t()) :: t()
  def record_retry(%__MODULE__{retry_count: n} = msg) do
    %{msg | retry_count: n + 1, last_retry_at: DateTime.utc_now()}
  end

  defp generate_id do
    :crypto.strong_rand_bytes(12) |> Base.url_encode64(padding: false)
  end
end

defmodule DeadLetter.Store do
  @moduledoc """
  ETS-backed dead-letter message store with queue-scoped queries.
  A supervised GenServer owns the table lifecycle.
  """

  use GenServer

  alias DeadLetter.Message

  @table :dead_letter_store

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec put(Message.t()) :: :ok
  def put(%Message{id: id} = msg) do
    :ets.insert(@table, {id, msg})
    :ok
  end

  @spec get(String.t()) :: {:ok, Message.t()} | {:error, :not_found}
  def get(id) when is_binary(id) do
    case :ets.lookup(@table, id) do
      [{^id, msg}] -> {:ok, msg}
      [] -> {:error, :not_found}
    end
  end

  @spec list_for_queue(String.t()) :: list(Message.t())
  def list_for_queue(queue) when is_binary(queue) do
    :ets.match_object(@table, {:_, %Message{queue: queue}})
    |> Enum.map(fn {_id, msg} -> msg end)
    |> Enum.sort_by(& &1.failed_at, {:asc, DateTime})
  end

  @spec delete(String.t()) :: :ok
  def delete(id) when is_binary(id) do
    :ets.delete(@table, id)
    :ok
  end

  @spec all() :: list(Message.t())
  def all do
    :ets.tab2list(@table) |> Enum.map(fn {_id, msg} -> msg end)
  end

  @spec size() :: non_neg_integer()
  def size, do: :ets.info(@table, :size)

  @impl GenServer
  def init(_opts) do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    {:ok, %{}}
  end
end

defmodule DeadLetter.Reprocessor do
  @moduledoc """
  Retries dead-letter messages by re-submitting their payloads to a
  caller-supplied handler function. Outcomes are reported per-message.
  """

  alias DeadLetter.{Message, Store}

  @type handler :: (map() -> :ok | {:error, term()})
  @type outcome :: %{id: String.t(), result: :reprocessed | :failed, reason: term() | nil}

  @spec reprocess_queue(String.t(), handler(), keyword()) :: list(outcome())
  def reprocess_queue(queue, handler_fn, opts \\ [])
      when is_binary(queue) and is_function(handler_fn, 1) do
    max_retries = Keyword.get(opts, :max_retries, 3)

    queue
    |> Store.list_for_queue()
    |> Enum.reject(fn msg -> msg.retry_count >= max_retries end)
    |> Enum.map(fn msg -> attempt_reprocess(msg, handler_fn) end)
  end

  defp attempt_reprocess(%Message{} = msg, handler_fn) do
    updated = Message.record_retry(msg)
    Store.put(updated)

    case handler_fn.(msg.payload) do
      :ok ->
        Store.delete(msg.id)
        %{id: msg.id, result: :reprocessed, reason: nil}

      {:error, reason} ->
        %{id: msg.id, result: :failed, reason: reason}
    end
  rescue
    err -> %{id: msg.id, result: :failed, reason: Exception.message(err)}
  end
end
```
