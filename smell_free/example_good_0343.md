```elixir
defmodule Platform.MessageBuffer do
  @moduledoc """
  A GenServer that buffers messages for a downstream consumer and applies
  configurable backpressure when the buffer reaches capacity.

  Producers can either drop, block, or receive an error when the buffer
  is full, depending on the `:overflow` strategy set at startup. The
  consumer flushes the buffer in configurable batch sizes.
  """

  use GenServer

  require Logger

  @type overflow_strategy :: :drop | :reject | :block
  @type push_result :: :ok | {:error, :buffer_full}
  @type flush_result :: {:ok, [term()]}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  Pushes a message into the buffer.

  Behaviour when the buffer is full depends on the configured `:overflow` strategy:
  - `:reject` — returns `{:error, :buffer_full}`
  - `:drop` — silently discards the oldest message and inserts the new one
  - `:block` — blocks the caller until space is available (up to `timeout_ms`)
  """
  @spec push(term(), keyword()) :: push_result()
  def push(message, opts \\ []) do
    timeout = Keyword.get(opts, :timeout_ms, 5_000)
    GenServer.call(__MODULE__, {:push, message}, timeout)
  end

  @doc """
  Flushes up to `count` messages from the buffer and returns them.
  Returns `{:ok, []}` when the buffer is empty.
  """
  @spec flush(pos_integer()) :: flush_result()
  def flush(count \\ 100) when is_integer(count) and count > 0 do
    GenServer.call(__MODULE__, {:flush, count})
  end

  @doc "Returns current buffer size and configured capacity."
  @spec stats() :: %{size: non_neg_integer(), capacity: pos_integer(), overflow: overflow_strategy()}
  def stats, do: GenServer.call(__MODULE__, :stats)

  @impl GenServer
  def init(opts) do
    {:ok, %{
      buffer: :queue.new(),
      size: 0,
      capacity: Keyword.get(opts, :capacity, 1_000),
      overflow: Keyword.get(opts, :overflow, :reject),
      waiters: :queue.new()
    }}
  end

  @impl GenServer
  def handle_call({:push, message}, from, state) do
    if state.size < state.capacity do
      new_state = enqueue(state, message)
      maybe_unblock_waiter(new_state)
      {:reply, :ok, new_state}
    else
      handle_overflow(state, message, from)
    end
  end

  @impl GenServer
  def handle_call({:flush, count}, _from, state) do
    {messages, new_queue, taken} = dequeue_n(state.buffer, count)
    new_state = %{state | buffer: new_queue, size: state.size - taken}
    drain_waiters(new_state, taken)
    {:reply, {:ok, messages}, new_state}
  end

  @impl GenServer
  def handle_call(:stats, _from, state) do
    {:reply, %{size: state.size, capacity: state.capacity, overflow: state.overflow}, state}
  end

  defp handle_overflow(%{overflow: :reject} = state, _message, _from) do
    {:reply, {:error, :buffer_full}, state}
  end

  defp handle_overflow(%{overflow: :drop} = state, message, _from) do
    {{:value, _dropped}, trimmed} = :queue.out(state.buffer)
    Logger.warning("[MessageBuffer] Dropping oldest message due to overflow")
    new_state = %{state | buffer: :queue.in(message, trimmed)}
    {:reply, :ok, new_state}
  end

  defp handle_overflow(%{overflow: :block} = state, message, from) do
    new_state = %{state | waiters: :queue.in({from, message}, state.waiters)}
    {:noreply, new_state}
  end

  defp enqueue(state, message) do
    %{state | buffer: :queue.in(message, state.buffer), size: state.size + 1}
  end

  defp dequeue_n(queue, count) do
    Enum.reduce_while(1..count, {[], queue, 0}, fn _, {acc, q, taken} ->
      case :queue.out(q) do
        {{:value, item}, rest} -> {:cont, {[item | acc], rest, taken + 1}}
        {:empty, _} -> {:halt, {acc, q, taken}}
      end
    end)
    |> then(fn {msgs, q, taken} -> {Enum.reverse(msgs), q, taken} end)
  end

  defp maybe_unblock_waiter(state), do: state

  defp drain_waiters(state, 0), do: state
  defp drain_waiters(%{waiters: waiters} = state, _space) do
    case :queue.out(waiters) do
      {{:value, {from, message}}, rest} ->
        new_state = enqueue(%{state | waiters: rest}, message)
        GenServer.reply(from, :ok)
        new_state
      {:empty, _} ->
        state
    end
  end
end
```
