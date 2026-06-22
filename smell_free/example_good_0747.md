# File: `example_good_747.md`

```elixir
defmodule DataSync.OfflineQueue do
  @moduledoc """
  Manages a persistent queue of operations recorded while the system
  was offline or unable to reach a remote service. Operations are
  replayed in order when connectivity is restored.

  The queue is backed by an ETS table for fast in-process reads and
  a GenServer for serialised writes, ensuring the queue stays consistent
  even under concurrent access.
  """

  use GenServer

  @table __MODULE__

  @type operation_id :: String.t()
  @type operation_type :: atom()

  @type operation :: %{
          required(:id) => operation_id(),
          required(:type) => operation_type(),
          required(:payload) => map(),
          required(:enqueued_at) => integer(),
          required(:attempt_count) => non_neg_integer()
        }

  @doc false
  def start_link(_opts) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @doc """
  Enqueues a new operation. Returns `{:ok, operation_id}`.
  """
  @spec enqueue(operation_type(), map()) :: {:ok, operation_id()}
  def enqueue(type, payload) when is_atom(type) and is_map(payload) do
    GenServer.call(__MODULE__, {:enqueue, type, payload})
  end

  @doc """
  Returns all pending operations in enqueue order (oldest first).
  """
  @spec pending() :: [operation()]
  def pending do
    @table
    |> :ets.tab2list()
    |> Enum.map(&elem(&1, 1))
    |> Enum.sort_by(& &1.enqueued_at)
  end

  @doc """
  Removes an operation from the queue after successful replay.
  """
  @spec acknowledge(operation_id()) :: :ok
  def acknowledge(operation_id) when is_binary(operation_id) do
    GenServer.cast(__MODULE__, {:acknowledge, operation_id})
  end

  @doc """
  Marks an attempt on a failed operation, incrementing its attempt count.
  """
  @spec record_failure(operation_id()) :: :ok | {:error, :not_found}
  def record_failure(operation_id) when is_binary(operation_id) do
    GenServer.call(__MODULE__, {:record_failure, operation_id})
  end

  @doc """
  Replays all pending operations through `handler_fn` in order.

  Each operation is passed to `handler_fn/1` which returns `:ok` or
  `{:error, reason}`. Successfully replayed operations are removed from
  the queue. Failed ones have their attempt count incremented.

  Returns `{:ok, %{replayed: count, failed: count}}`.
  """
  @spec replay((operation() -> :ok | {:error, term()})) ::
          {:ok, %{replayed: non_neg_integer(), failed: non_neg_integer()}}
  def replay(handler_fn) when is_function(handler_fn, 1) do
    operations = pending()

    {replayed, failed} =
      Enum.reduce(operations, {0, 0}, fn op, {ok_count, err_count} ->
        case handler_fn.(op) do
          :ok ->
            acknowledge(op.id)
            {ok_count + 1, err_count}

          {:error, _reason} ->
            record_failure(op.id)
            {ok_count, err_count + 1}
        end
      end)

    {:ok, %{replayed: replayed, failed: failed}}
  end

  @doc """
  Returns the count of pending operations.
  """
  @spec size() :: non_neg_integer()
  def size do
    :ets.info(@table, :size)
  end

  @doc """
  Clears all operations that have exceeded `max_attempts` retries.

  Returns the count of removed operations.
  """
  @spec prune_exhausted(pos_integer()) :: non_neg_integer()
  def prune_exhausted(max_attempts) when is_integer(max_attempts) and max_attempts > 0 do
    GenServer.call(__MODULE__, {:prune_exhausted, max_attempts})
  end

  @impl GenServer
  def init(_opts) do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    {:ok, %{}}
  end

  @impl GenServer
  def handle_call({:enqueue, type, payload}, _from, state) do
    id = generate_id()
    op = %{id: id, type: type, payload: payload, enqueued_at: System.monotonic_time(:millisecond), attempt_count: 0}
    :ets.insert(@table, {id, op})
    {:reply, {:ok, id}, state}
  end

  @impl GenServer
  def handle_call({:record_failure, op_id}, _from, state) do
    case :ets.lookup(@table, op_id) do
      [{^op_id, op}] ->
        updated = %{op | attempt_count: op.attempt_count + 1}
        :ets.insert(@table, {op_id, updated})
        {:reply, :ok, state}

      [] ->
        {:reply, {:error, :not_found}, state}
    end
  end

  @impl GenServer
  def handle_call({:prune_exhausted, max_attempts}, _from, state) do
    count =
      :ets.tab2list(@table)
      |> Enum.filter(fn {_id, op} -> op.attempt_count >= max_attempts end)
      |> Enum.reduce(0, fn {id, _op}, acc ->
        :ets.delete(@table, id)
        acc + 1
      end)

    {:reply, count, state}
  end

  @impl GenServer
  def handle_cast({:acknowledge, op_id}, state) do
    :ets.delete(@table, op_id)
    {:noreply, state}
  end

  defp generate_id do
    :crypto.strong_rand_bytes(12) |> Base.url_encode64(padding: false)
  end
end
```
