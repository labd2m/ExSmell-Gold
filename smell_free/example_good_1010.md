```elixir
defmodule AckQueue do
  @moduledoc """
  A GenServer-backed queue that requires explicit acknowledgement before
  the next item is delivered to a consumer.

  `dequeue/1` returns `{:ok, item, ack_ref}`. The caller must call
  `ack/2` with the reference once processing succeeds. If processing fails,
  `nack/2` returns the item to the front of the queue for redelivery.
  Items that are neither acked nor nacked within `ack_timeout_ms` are
  automatically re-queued, preventing silent loss from consumer crashes.
  """

  use GenServer

  @type ack_ref :: reference()
  @type opts :: [name: atom(), ack_timeout_ms: pos_integer()]

  @spec start_link(opts()) :: GenServer.on_start()
  def start_link(opts) do
    name = Keyword.fetch!(opts, :name)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @spec enqueue(atom(), term()) :: :ok
  def enqueue(queue, item) when is_atom(queue) do
    GenServer.cast(queue, {:enqueue, item})
  end

  @spec enqueue_batch(atom(), [term()]) :: :ok
  def enqueue_batch(queue, items) when is_atom(queue) and is_list(items) do
    Enum.each(items, &enqueue(queue, &1))
  end

  @spec dequeue(atom()) :: {:ok, term(), ack_ref()} | {:error, :empty}
  def dequeue(queue) when is_atom(queue) do
    GenServer.call(queue, :dequeue)
  end

  @spec ack(atom(), ack_ref()) :: :ok | {:error, :unknown_ref}
  def ack(queue, ref) when is_atom(queue) and is_reference(ref) do
    GenServer.call(queue, {:ack, ref})
  end

  @spec nack(atom(), ack_ref()) :: :ok | {:error, :unknown_ref}
  def nack(queue, ref) when is_atom(queue) and is_reference(ref) do
    GenServer.call(queue, {:nack, ref})
  end

  @spec size(atom()) :: %{queued: non_neg_integer(), in_flight: non_neg_integer()}
  def size(queue) when is_atom(queue) do
    GenServer.call(queue, :size)
  end

  @impl GenServer
  def init(opts) do
    ack_timeout = Keyword.get(opts, :ack_timeout_ms, 30_000)
    {:ok, %{queue: :queue.new(), in_flight: %{}, ack_timeout_ms: ack_timeout}}
  end

  @impl GenServer
  def handle_cast({:enqueue, item}, state) do
    {:noreply, %{state | queue: :queue.in(item, state.queue)}}
  end

  @impl GenServer
  def handle_call(:dequeue, _from, state) do
    case :queue.out(state.queue) do
      {{:value, item}, remaining} ->
        ref = make_ref()
        timer = Process.send_after(self(), {:ack_timeout, ref}, state.ack_timeout_ms)
        in_flight = Map.put(state.in_flight, ref, {item, timer})
        {:reply, {:ok, item, ref}, %{state | queue: remaining, in_flight: in_flight}}

      {:empty, _} ->
        {:reply, {:error, :empty}, state}
    end
  end

  def handle_call({:ack, ref}, _from, state) do
    case Map.fetch(state.in_flight, ref) do
      {:ok, {_item, timer}} ->
        Process.cancel_timer(timer)
        {:reply, :ok, %{state | in_flight: Map.delete(state.in_flight, ref)}}

      :error ->
        {:reply, {:error, :unknown_ref}, state}
    end
  end

  def handle_call({:nack, ref}, _from, state) do
    case Map.fetch(state.in_flight, ref) do
      {:ok, {item, timer}} ->
        Process.cancel_timer(timer)
        requeued = :queue.in_r(item, state.queue)
        {:reply, :ok, %{state | queue: requeued, in_flight: Map.delete(state.in_flight, ref)}}

      :error ->
        {:reply, {:error, :unknown_ref}, state}
    end
  end

  def handle_call(:size, _from, state) do
    info = %{queued: :queue.len(state.queue), in_flight: map_size(state.in_flight)}
    {:reply, info, state}
  end

  @impl GenServer
  def handle_info({:ack_timeout, ref}, state) do
    case Map.fetch(state.in_flight, ref) do
      {:ok, {item, _timer}} ->
        requeued = :queue.in_r(item, state.queue)
        {:noreply, %{state | queue: requeued, in_flight: Map.delete(state.in_flight, ref)}}

      :error ->
        {:noreply, state}
    end
  end
end
```
