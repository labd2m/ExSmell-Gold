# File: `example_good_195.md`

```elixir
defmodule Queue.PriorityScheduler do
  @moduledoc """
  GenServer implementing a bounded priority queue for job scheduling.

  Jobs are enqueued with an integer priority (lower values run first).
  The scheduler dispatches the highest-priority pending job to a
  registered handler whenever one is available, applying back-pressure
  by rejecting enqueues when the queue is at capacity.
  """

  use GenServer

  require Logger

  @default_capacity 1_000

  @type priority :: non_neg_integer()
  @type job_id :: String.t()
  @type handler :: module()

  @type job :: %{
          required(:id) => job_id(),
          required(:priority) => priority(),
          required(:payload) => map()
        }

  @type opts :: [
          capacity: pos_integer(),
          handler: handler()
        ]

  @doc false
  def start_link(opts) when is_list(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Adds a job to the scheduling queue.

  Returns `:ok` if enqueued, `{:error, :at_capacity}` when the queue
  has reached its configured limit.
  """
  @spec enqueue(job()) :: :ok | {:error, :at_capacity}
  def enqueue(%{id: _, priority: p, payload: _} = job) when is_integer(p) and p >= 0 do
    GenServer.call(__MODULE__, {:enqueue, job})
  end

  @doc """
  Returns a snapshot of queue depth broken down by priority bucket.
  """
  @spec stats() :: %{depth: non_neg_integer(), dispatched: non_neg_integer(), dropped: non_neg_integer()}
  def stats do
    GenServer.call(__MODULE__, :stats)
  end

  @doc """
  Removes all pending jobs from the queue without dispatching them.
  Returns the count of purged jobs.
  """
  @spec purge() :: non_neg_integer()
  def purge do
    GenServer.call(__MODULE__, :purge)
  end

  @impl GenServer
  def init(opts) do
    handler = Keyword.fetch!(opts, :handler)
    capacity = Keyword.get(opts, :capacity, @default_capacity)

    {:ok, %{queue: [], capacity: capacity, handler: handler, dispatched: 0, dropped: 0}}
  end

  @impl GenServer
  def handle_call({:enqueue, job}, _from, state) do
    if length(state.queue) >= state.capacity do
      {:reply, {:error, :at_capacity}, %{state | dropped: state.dropped + 1}}
    else
      new_queue = insert_sorted(state.queue, job)
      new_state = %{state | queue: new_queue}
      send(self(), :dispatch)
      {:reply, :ok, new_state}
    end
  end

  @impl GenServer
  def handle_call(:stats, _from, state) do
    stats = %{depth: length(state.queue), dispatched: state.dispatched, dropped: state.dropped}
    {:reply, stats, state}
  end

  @impl GenServer
  def handle_call(:purge, _from, state) do
    count = length(state.queue)
    {:reply, count, %{state | queue: []}}
  end

  @impl GenServer
  def handle_info(:dispatch, %{queue: []} = state) do
    {:noreply, state}
  end

  @impl GenServer
  def handle_info(:dispatch, %{queue: [next | rest]} = state) do
    dispatch_job(next, state.handler)
    {:noreply, %{state | queue: rest, dispatched: state.dispatched + 1}}
  end

  defp insert_sorted([], job), do: [job]

  defp insert_sorted([head | _rest] = queue, job) when head.priority > job.priority do
    [job | queue]
  end

  defp insert_sorted([head | rest], job) do
    [head | insert_sorted(rest, job)]
  end

  defp dispatch_job(job, handler) do
    Task.Supervisor.start_child(Queue.TaskSupervisor, fn ->
      case handler.handle(job) do
        :ok ->
          :ok

        {:error, reason} ->
          Logger.warning("Job #{job.id} failed: #{inspect(reason)}")
      end
    end)
  end
end
```
