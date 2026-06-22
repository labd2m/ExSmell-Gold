```elixir
defmodule Queue.BoundedWorkQueue do
  @moduledoc """
  A supervised GenServer that implements a bounded, in-memory work queue.
  When the queue reaches capacity, new items are either dropped (`:drop`)
  or cause the caller to block until space is available (`:block`), depending
  on the configured overflow strategy. Consumer workers are started as a
  `Task.Supervisor` pool that drains the queue concurrently. Queue depth is
  exposed via telemetry for back-pressure monitoring.
  """

  use GenServer

  require Logger

  @type item :: term()
  @type overflow_strategy :: :drop | :block
  @type queue_opts :: [
          capacity: pos_integer(),
          concurrency: pos_integer(),
          overflow: overflow_strategy(),
          handler: (item() -> :ok | {:error, term()})
        ]

  @telemetry_event [:queue, :bounded, :depth]

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @spec start_link(queue_opts()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  Enqueues `item` for processing. Behaviour when the queue is full depends
  on the `:overflow` option: `:drop` returns `{:error, :queue_full}` immediately;
  `:block` blocks the caller until space is available.
  """
  @spec enqueue(atom() | pid(), item()) :: :ok | {:error, :queue_full}
  def enqueue(queue \\ __MODULE__, item) do
    GenServer.call(queue, {:enqueue, item})
  end

  @doc """
  Returns the current depth and capacity of the queue.
  """
  @spec stats(atom() | pid()) :: %{depth: non_neg_integer(), capacity: pos_integer(), in_flight: non_neg_integer()}
  def stats(queue \\ __MODULE__) do
    GenServer.call(queue, :stats)
  end

  # ---------------------------------------------------------------------------
  # GenServer callbacks
  # ---------------------------------------------------------------------------

  @impl GenServer
  def init(opts) do
    capacity = Keyword.fetch!(opts, :capacity)
    concurrency = Keyword.get(opts, :concurrency, 4)
    overflow = Keyword.get(opts, :overflow, :drop)
    handler = Keyword.fetch!(opts, :handler)

    {:ok, task_sup} = Task.Supervisor.start_link()

    state = %{
      queue: :queue.new(),
      capacity: capacity,
      concurrency: concurrency,
      overflow: overflow,
      handler: handler,
      in_flight: 0,
      task_sup: task_sup,
      blocked_callers: []
    }

    {:ok, state}
  end

  @impl GenServer
  def handle_call({:enqueue, item}, from, state) do
    depth = :queue.len(state.queue)

    cond do
      depth < state.capacity ->
        new_state = %{state | queue: :queue.in(item, state.queue)}
        emit_depth_telemetry(new_state)
        dispatch_if_available(new_state)
        {:reply, :ok, new_state}

      state.overflow == :drop ->
        Logger.warning("Queue full, item dropped", capacity: state.capacity)
        {:reply, {:error, :queue_full}, state}

      state.overflow == :block ->
        new_state = %{state | blocked_callers: [{from, item} | state.blocked_callers]}
        {:noreply, new_state}
    end
  end

  def handle_call(:stats, _from, state) do
    stats = %{
      depth: :queue.len(state.queue),
      capacity: state.capacity,
      in_flight: state.in_flight
    }

    {:reply, stats, state}
  end

  @impl GenServer
  def handle_info({:task_done, result}, state) do
    if result != :ok do
      Logger.warning("Work item processing failed", reason: inspect(result))
    end

    new_state = %{state | in_flight: max(0, state.in_flight - 1)}
    unblocked = unblock_caller(new_state)
    {:noreply, dispatch_if_available(unblocked)}
  end

  def handle_info({:DOWN, _ref, :process, _pid, _reason}, state) do
    new_state = %{state | in_flight: max(0, state.in_flight - 1)}
    {:noreply, dispatch_if_available(new_state)}
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp dispatch_if_available(%{in_flight: in_flight, concurrency: cap} = state)
       when in_flight >= cap, do: state

  defp dispatch_if_available(state) do
    case :queue.out(state.queue) do
      {:empty, _} ->
        state

      {{:value, item}, rest} ->
        parent = self()
        handler = state.handler

        task =
          Task.Supervisor.async_nolink(state.task_sup, fn ->
            result = handler.(item)
            send(parent, {:task_done, result})
            result
          end)

        Process.monitor(task.pid)
        new_state = %{state | queue: rest, in_flight: state.in_flight + 1}
        emit_depth_telemetry(new_state)
        dispatch_if_available(new_state)
    end
  end

  defp unblock_caller(%{blocked_callers: []} = state), do: state

  defp unblock_caller(%{blocked_callers: [{from, item} | rest], capacity: cap} = state) do
    depth = :queue.len(state.queue)

    if depth < cap do
      GenServer.reply(from, :ok)
      %{state | queue: :queue.in(item, state.queue), blocked_callers: rest}
    else
      state
    end
  end

  defp emit_depth_telemetry(state) do
    :telemetry.execute(@telemetry_event, %{depth: :queue.len(state.queue)}, %{
      capacity: state.capacity
    })
  end
end
```
