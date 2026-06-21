```elixir
defmodule Platform.PriorityQueue do
  @moduledoc """
  An in-memory priority job queue backed by a GenServer with three priority
  lanes: `:high`, `:normal`, and `:low`.

  Workers dequeue jobs via `dequeue/1`, always consuming higher-priority
  lanes before lower ones. Enqueueing and dequeueing are both O(1) with
  respect to queue depth, using per-priority Erlang queues.
  """

  use GenServer

  @type priority :: :high | :normal | :low
  @type job :: %{id: String.t(), payload: term(), priority: priority(), enqueued_at: DateTime.t()}
  @type dequeue_result :: {:ok, job()} | {:error, :empty}

  @priorities [:high, :normal, :low]

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  Enqueues a job payload at the given priority level.
  Returns the assigned job struct.
  """
  @spec enqueue(priority(), term()) :: {:ok, job()}
  def enqueue(priority, payload) when priority in @priorities do
    GenServer.call(__MODULE__, {:enqueue, priority, payload})
  end

  @doc """
  Dequeues the next available job, consuming `:high` before `:normal`
  before `:low`. Returns `{:error, :empty}` when all lanes are empty.
  """
  @spec dequeue() :: dequeue_result()
  def dequeue, do: GenServer.call(__MODULE__, :dequeue)

  @doc "Returns the number of jobs in each priority lane."
  @spec depth() :: %{high: non_neg_integer(), normal: non_neg_integer(), low: non_neg_integer()}
  def depth, do: GenServer.call(__MODULE__, :depth)

  @doc "Returns the total number of jobs across all lanes."
  @spec total() :: non_neg_integer()
  def total do
    depth() |> Map.values() |> Enum.sum()
  end

  @impl GenServer
  def init(_opts) do
    queues = Map.new(@priorities, fn p -> {p, :queue.new()} end)
    {:ok, %{queues: queues}}
  end

  @impl GenServer
  def handle_call({:enqueue, priority, payload}, _from, state) do
    job = %{
      id: generate_id(),
      payload: payload,
      priority: priority,
      enqueued_at: DateTime.utc_now()
    }

    new_queues = Map.update!(state.queues, priority, &:queue.in(job, &1))
    {:reply, {:ok, job}, %{state | queues: new_queues}}
  end

  @impl GenServer
  def handle_call(:dequeue, _from, state) do
    case next_job(state.queues) do
      {:ok, job, updated_queues} ->
        {:reply, {:ok, job}, %{state | queues: updated_queues}}

      :empty ->
        {:reply, {:error, :empty}, state}
    end
  end

  @impl GenServer
  def handle_call(:depth, _from, state) do
    counts = Map.new(state.queues, fn {p, q} -> {p, :queue.len(q)} end)
    {:reply, counts, state}
  end

  defp next_job(queues) do
    Enum.reduce_while(@priorities, :empty, fn priority, _acc ->
      case :queue.out(Map.fetch!(queues, priority)) do
        {{:value, job}, remaining} ->
          {:halt, {:ok, job, Map.put(queues, priority, remaining)}}

        {:empty, _} ->
          {:cont, :empty}
      end
    end)
  end

  defp generate_id do
    8
    |> :crypto.strong_rand_bytes()
    |> Base.encode16(case: :lower)
  end
end
```
