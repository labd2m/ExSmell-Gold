```elixir
defmodule MyApp.Infra.BackpressureQueue do
  @moduledoc """
  A GenServer-backed bounded work queue that applies back-pressure to
  producers when the queue depth reaches its configured limit. Producers
  call `push/2` which blocks until a slot is available or a timeout
  elapses. Consumers call `pop/1` which blocks until an item is available.
  Both operations are implemented as GenServer calls so ordering is
  preserved and no additional synchronisation primitives are required.
  """

  use GenServer

  @default_capacity 1_000
  @default_timeout_ms 5_000

  @type item :: term()

  @doc "Starts the bounded queue."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  Pushes `item` onto the queue. Blocks up to `timeout_ms` when the
  queue is at capacity. Returns `:ok` or `{:error, :timeout}`.
  """
  @spec push(item(), pos_integer()) :: :ok | {:error, :timeout}
  def push(item, timeout_ms \\ @default_timeout_ms) do
    GenServer.call(__MODULE__, {:push, item}, timeout_ms + 500)
  catch
    :exit, {:timeout, _} -> {:error, :timeout}
  end

  @doc """
  Pops the next item from the queue. Blocks up to `timeout_ms` when
  the queue is empty. Returns `{:ok, item}` or `{:error, :timeout}`.
  """
  @spec pop(pos_integer()) :: {:ok, item()} | {:error, :timeout}
  def pop(timeout_ms \\ @default_timeout_ms) do
    GenServer.call(__MODULE__, :pop, timeout_ms + 500)
  catch
    :exit, {:timeout, _} -> {:error, :timeout}
  end

  @doc "Returns current queue depth and capacity."
  @spec stats() :: %{depth: non_neg_integer(), capacity: pos_integer()}
  def stats, do: GenServer.call(__MODULE__, :stats)

  @impl GenServer
  def init(opts) do
    {:ok, %{
      queue: :queue.new(),
      capacity: Keyword.get(opts, :capacity, @default_capacity),
      waiting_producers: :queue.new(),
      waiting_consumers: :queue.new()
    }}
  end

  @impl GenServer
  def handle_call({:push, item}, from, state) do
    cond do
      not :queue.is_empty(state.waiting_consumers) ->
        {{:value, consumer_from}, rest} = :queue.out(state.waiting_consumers)
        GenServer.reply(consumer_from, {:ok, item})
        GenServer.reply(from, :ok)
        {:noreply, %{state | waiting_consumers: rest}}

      :queue.len(state.queue) < state.capacity ->
        {:reply, :ok, %{state | queue: :queue.in(item, state.queue)}}

      true ->
        new_producers = :queue.in({from, item}, state.waiting_producers)
        {:noreply, %{state | waiting_producers: new_producers}}
    end
  end

  @impl GenServer
  def handle_call(:pop, from, state) do
    case :queue.out(state.queue) do
      {{:value, item}, rest_queue} ->
        state = drain_producer(%{state | queue: rest_queue})
        {:reply, {:ok, item}, state}

      {:empty, _} ->
        case :queue.out(state.waiting_producers) do
          {{:value, {producer_from, item}}, rest_producers} ->
            GenServer.reply(producer_from, :ok)
            {:reply, {:ok, item}, %{state | waiting_producers: rest_producers}}

          {:empty, _} ->
            new_consumers = :queue.in(from, state.waiting_consumers)
            {:noreply, %{state | waiting_consumers: new_consumers}}
        end
    end
  end

  @impl GenServer
  def handle_call(:stats, _from, state) do
    {:reply, %{depth: :queue.len(state.queue), capacity: state.capacity}, state}
  end

  @spec drain_producer(map()) :: map()
  defp drain_producer(state) do
    case :queue.out(state.waiting_producers) do
      {{:value, {from, item}}, rest} ->
        GenServer.reply(from, :ok)
        %{state | queue: :queue.in(item, state.queue), waiting_producers: rest}

      {:empty, _} ->
        state
    end
  end
end
```
