```elixir
defmodule Infra.WorkerPool do
  @moduledoc """
  A fixed-size worker pool backed by a GenServer dispatcher and a set of
  supervised worker processes. Work items are queued when all workers are
  busy. Workers report completion so the dispatcher can immediately assign
  the next queued item. Pool size and the worker module are configurable
  at startup.
  """

  use GenServer

  require Logger

  @type work_item :: term()
  @type worker_fn :: module()

  @doc "Starts the worker pool with a fixed number of `size` workers."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc "Submits `item` to the pool for processing. Queues when all workers are busy."
  @spec submit(GenServer.server(), work_item()) :: :ok
  def submit(server \\ __MODULE__, item) do
    GenServer.cast(server, {:submit, item})
  end

  @doc "Returns the current queue depth and count of busy workers."
  @spec stats(GenServer.server()) :: %{queued: non_neg_integer(), busy: non_neg_integer()}
  def stats(server \\ __MODULE__) do
    GenServer.call(server, :stats)
  end

  @impl GenServer
  def init(opts) do
    size = Keyword.get(opts, :size, 5)
    worker_module = Keyword.fetch!(opts, :worker_module)
    supervisor = Keyword.fetch!(opts, :supervisor)

    workers = start_workers(supervisor, worker_module, size)

    state = %{
      workers: workers,
      idle: Enum.map(workers, & &1.pid),
      busy: MapSet.new(),
      queue: :queue.new(),
      worker_module: worker_module,
      supervisor: supervisor
    }

    {:ok, state}
  end

  @impl GenServer
  def handle_cast({:submit, item}, state) do
    case state.idle do
      [worker_pid | rest] ->
        assign(worker_pid, item)
        {:noreply, %{state | idle: rest, busy: MapSet.put(state.busy, worker_pid)}}

      [] ->
        {:noreply, %{state | queue: :queue.in(item, state.queue)}}
    end
  end

  @impl GenServer
  def handle_call(:stats, _from, state) do
    stats = %{queued: :queue.len(state.queue), busy: MapSet.size(state.busy)}
    {:reply, stats, state}
  end

  @impl GenServer
  def handle_info({:worker_done, worker_pid}, state) do
    new_busy = MapSet.delete(state.busy, worker_pid)

    case :queue.out(state.queue) do
      {{:value, item}, rest} ->
        assign(worker_pid, item)
        {:noreply, %{state | queue: rest, busy: MapSet.put(new_busy, worker_pid)}}

      {:empty, _} ->
        {:noreply, %{state | idle: [worker_pid | state.idle], busy: new_busy}}
    end
  end

  defp start_workers(supervisor, module, count) do
    dispatcher = self()

    Enum.map(1..count, fn _ ->
      {:ok, pid} =
        Task.Supervisor.start_child(supervisor, fn ->
          worker_loop(module, dispatcher)
        end)

      %{pid: pid}
    end)
  end

  defp worker_loop(module, dispatcher) do
    receive do
      {:work, item} ->
        module.process(item)
        send(dispatcher, {:worker_done, self()})
        worker_loop(module, dispatcher)
    end
  end

  defp assign(worker_pid, item) do
    send(worker_pid, {:work, item})
  end
end
```
