```elixir
defmodule Queue.PriorityLevel do
  @moduledoc false

  @levels [:high, :normal, :low]

  @spec all() :: [:high | :normal | :low]
  def all, do: @levels

  @spec valid?(atom()) :: boolean()
  def valid?(level), do: level in @levels

  @spec compare(:high | :normal | :low, :high | :normal | :low) :: :lt | :eq | :gt
  def compare(a, b) do
    index = fn l -> Enum.find_index(@levels, &(&1 == l)) end

    cond do
      index.(a) < index.(b) -> :lt
      index.(a) == index.(b) -> :eq
      true -> :gt
    end
  end
end

defmodule Queue.PriorityQueue do
  @moduledoc """
  A supervised, three-level priority message queue.

  Messages enqueued at `:high` priority are always dequeued before `:normal`,
  and `:normal` before `:low`. Within each level, ordering is FIFO.
  Consumers call `dequeue/1`, which blocks via `GenServer.call/3` until a
  message becomes available or the configured timeout elapses.
  Producers call `enqueue/3`, which is asynchronous and always returns `:ok`.
  """

  use GenServer

  alias Queue.PriorityLevel

  @type priority :: :high | :normal | :low
  @type opts :: [name: atom(), dequeue_timeout_ms: pos_integer()]

  @spec start_link(opts()) :: GenServer.on_start()
  def start_link(opts) do
    name = Keyword.fetch!(opts, :name)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @spec enqueue(atom(), term(), priority()) :: :ok
  def enqueue(queue, message, priority \\ :normal)
      when is_atom(queue) and PriorityLevel.valid?(priority) do
    GenServer.cast(queue, {:enqueue, message, priority})
  end

  @spec dequeue(atom(), timeout()) :: {:ok, {term(), priority()}} | {:error, :timeout}
  def dequeue(queue, timeout \\ 5_000) when is_atom(queue) do
    GenServer.call(queue, :dequeue, timeout)
  rescue
    _ -> {:error, :timeout}
  end

  @spec size(atom()) :: %{high: non_neg_integer(), normal: non_neg_integer(), low: non_neg_integer()}
  def size(queue) when is_atom(queue) do
    GenServer.call(queue, :size)
  end

  @impl GenServer
  def init(opts) do
    state = %{
      queues: %{high: :queue.new(), normal: :queue.new(), low: :queue.new()},
      waiting: :queue.new(),
      dequeue_timeout_ms: Keyword.get(opts, :dequeue_timeout_ms, 30_000)
    }

    {:ok, state}
  end

  @impl GenServer
  def handle_cast({:enqueue, message, priority}, state) do
    case :queue.out(state.waiting) do
      {{:value, {from, _ref}}, remaining_waiting} ->
        GenServer.reply(from, {:ok, {message, priority}})
        {:noreply, %{state | waiting: remaining_waiting}}

      {:empty, _} ->
        updated_queue = :queue.in(message, state.queues[priority])
        {:noreply, %{state | queues: Map.put(state.queues, priority, updated_queue)}}
    end
  end

  @impl GenServer
  def handle_call(:dequeue, from, state) do
    case pop_highest(state.queues) do
      {:ok, {message, priority}, updated_queues} ->
        {:reply, {:ok, {message, priority}}, %{state | queues: updated_queues}}

      :empty ->
        ref = Process.send_after(self(), {:dequeue_timeout, from}, state.dequeue_timeout_ms)
        {:noreply, %{state | waiting: :queue.in({from, ref}, state.waiting)}}
    end
  end

  def handle_call(:size, _from, state) do
    sizes = Map.new(state.queues, fn {level, q} -> {level, :queue.len(q)} end)
    {:reply, sizes, state}
  end

  @impl GenServer
  def handle_info({:dequeue_timeout, from}, state) do
    GenServer.reply(from, {:error, :timeout})
    {:noreply, state}
  end

  defp pop_highest(queues) do
    Enum.find_value(PriorityLevel.all(), :empty, fn level ->
      case :queue.out(queues[level]) do
        {{:value, message}, remaining} ->
          {:ok, {message, level}, Map.put(queues, level, remaining)}

        {:empty, _} ->
          nil
      end
    end)
  end
end
```
