```elixir
defmodule Messaging.DeadLetterQueue do
  @moduledoc """
  A GenServer that collects, stores, and provides tooling for inspecting and
  reprocessing failed messages that could not be delivered after all retry
  attempts were exhausted.

  Messages are persisted to the database on arrival. Operators can query
  the queue, replay individual messages, or discard them via the public API.
  """

  use GenServer

  require Logger

  alias Messaging.{Repo, DeadLetter}

  @type message_id :: pos_integer()
  @type dead_letter :: %{
          id: message_id(),
          queue: String.t(),
          payload: map(),
          error_reason: String.t(),
          failed_at: DateTime.t(),
          retry_count: non_neg_integer()
        }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Enqueues a message into the dead-letter store after it has exhausted retries.
  """
  @spec enqueue(String.t(), map(), String.t(), non_neg_integer()) ::
          {:ok, dead_letter()} | {:error, Ecto.Changeset.t()}
  def enqueue(queue, payload, error_reason, retry_count)
      when is_binary(queue) and is_map(payload) do
    GenServer.call(__MODULE__, {:enqueue, queue, payload, error_reason, retry_count})
  end

  @doc "Returns all dead-letter messages for a given queue, newest first."
  @spec list(String.t(), keyword()) :: [dead_letter()]
  def list(queue, opts \\ []) when is_binary(queue) do
    limit = Keyword.get(opts, :limit, 50)
    GenServer.call(__MODULE__, {:list, queue, limit})
  end

  @doc """
  Replays a dead-letter message by dispatching it to the original handler.
  Removes the entry on successful reprocessing.
  """
  @spec replay(message_id(), module()) :: :ok | {:error, term()}
  def replay(message_id, handler_module) when is_integer(message_id) and is_atom(handler_module) do
    GenServer.call(__MODULE__, {:replay, message_id, handler_module}, 30_000)
  end

  @doc "Permanently discards a dead-letter message by id."
  @spec discard(message_id()) :: :ok | {:error, :not_found}
  def discard(message_id) when is_integer(message_id) do
    GenServer.call(__MODULE__, {:discard, message_id})
  end

  @impl GenServer
  def init(_opts), do: {:ok, %{}}

  @impl GenServer
  def handle_call({:enqueue, queue, payload, reason, retries}, _from, state) do
    attrs = %{queue: queue, payload: payload, error_reason: reason, retry_count: retries, failed_at: DateTime.utc_now()}
    result = %DeadLetter{} |> DeadLetter.changeset(attrs) |> Repo.insert()
    {:reply, result, state}
  end

  @impl GenServer
  def handle_call({:list, queue, limit}, _from, state) do
    import Ecto.Query
    records = from(d in DeadLetter, where: d.queue == ^queue, order_by: [desc: d.failed_at], limit: ^limit)
              |> Repo.all()
    {:reply, records, state}
  end

  @impl GenServer
  def handle_call({:replay, message_id, handler_module}, _from, state) do
    case Repo.get(DeadLetter, message_id) do
      nil ->
        {:reply, {:error, :not_found}, state}

      dead_letter ->
        result = safe_replay(dead_letter, handler_module)
        if match?(:ok, result), do: Repo.delete(dead_letter)
        {:reply, result, state}
    end
  end

  @impl GenServer
  def handle_call({:discard, message_id}, _from, state) do
    case Repo.get(DeadLetter, message_id) do
      nil -> {:reply, {:error, :not_found}, state}
      record -> Repo.delete(record); {:reply, :ok, state}
    end
  end

  defp safe_replay(%DeadLetter{payload: payload, queue: queue}, handler_module) do
    handler_module.handle(payload)
  rescue
    error ->
      Logger.error("[DLQ] Replay failed", queue: queue, error: inspect(error))
      {:error, error}
  end
end
```
