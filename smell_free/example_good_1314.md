```elixir
defmodule JobQueue.Server do
  @moduledoc """
  A priority-aware in-memory job queue. Jobs are enqueued at `:high`,
  `:normal`, or `:low` priority and dequeued in that order.
  """

  use GenServer

  @type priority :: :high | :normal | :low
  @type job_id :: String.t()

  @type job :: %{
          id: job_id(),
          payload: term(),
          priority: priority(),
          enqueued_at_ms: integer()
        }

  @type state :: %{
          high: :queue.queue(job()),
          normal: :queue.queue(job()),
          low: :queue.queue(job()),
          size: non_neg_integer()
        }

  @priority_order [:high, :normal, :low]

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @spec enqueue(atom(), term(), priority()) :: {:ok, job_id()}
  def enqueue(server \\ __MODULE__, payload, priority \\ :normal)
      when priority in [:high, :normal, :low] do
    GenServer.call(server, {:enqueue, payload, priority})
  end

  @spec dequeue(atom()) :: {:ok, job()} | {:error, :empty}
  def dequeue(server \\ __MODULE__) do
    GenServer.call(server, :dequeue)
  end

  @spec peek(atom()) :: {:ok, job()} | {:error, :empty}
  def peek(server \\ __MODULE__) do
    GenServer.call(server, :peek)
  end

  @spec size(atom()) :: non_neg_integer()
  def size(server \\ __MODULE__) do
    GenServer.call(server, :size)
  end

  @impl GenServer
  def init(_opts) do
    {:ok, %{high: :queue.new(), normal: :queue.new(), low: :queue.new(), size: 0}}
  end

  @impl GenServer
  def handle_call({:enqueue, payload, priority}, _from, state) do
    id = random_id()
    job = %{id: id, payload: payload, priority: priority, enqueued_at_ms: now_ms()}
    updated = state |> Map.update!(priority, &:queue.in(job, &1)) |> Map.update!(:size, &(&1 + 1))
    {:reply, {:ok, id}, updated}
  end

  def handle_call(:dequeue, _from, %{size: 0} = state) do
    {:reply, {:error, :empty}, state}
  end

  def handle_call(:dequeue, _from, state) do
    {job, updated} = pop_by_priority(state)
    {:reply, {:ok, job}, updated}
  end

  def handle_call(:peek, _from, %{size: 0} = state) do
    {:reply, {:error, :empty}, state}
  end

  def handle_call(:peek, _from, state) do
    priority = Enum.find(@priority_order, fn p -> not :queue.is_empty(Map.get(state, p)) end)
    {:value, job} = :queue.peek(Map.get(state, priority))
    {:reply, {:ok, job}, state}
  end

  def handle_call(:size, _from, state) do
    {:reply, state.size, state}
  end

  defp pop_by_priority(state) do
    priority = Enum.find(@priority_order, fn p -> not :queue.is_empty(Map.get(state, p)) end)
    {{:value, job}, new_queue} = :queue.out(Map.get(state, priority))
    updated = state |> Map.put(priority, new_queue) |> Map.update!(:size, &(&1 - 1))
    {job, updated}
  end

  defp now_ms, do: System.monotonic_time(:millisecond)

  defp random_id do
    :crypto.strong_rand_bytes(8) |> Base.url_encode64(padding: false)
  end
end
```
