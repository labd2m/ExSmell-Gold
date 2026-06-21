```elixir
defmodule Pipeline.Worker do
  @moduledoc """
  A transient, supervised worker process for executing a single pipeline job.

  Workers are started with `:temporary` restart strategy so the supervisor
  does not attempt to restart them after normal or error termination.
  The pool monitors each worker PID to track available concurrency slots.
  """

  use GenServer, restart: :temporary

  @spec start_link(term()) :: GenServer.on_start()
  def start_link(job) do
    GenServer.start_link(__MODULE__, job)
  end

  @impl GenServer
  def init(job) do
    send(self(), :execute)
    {:ok, job}
  end

  @impl GenServer
  def handle_info(:execute, job) do
    run(job)
    {:stop, :normal, job}
  end

  defp run({module, function, args})
       when is_atom(module) and is_atom(function) and is_list(args) do
    apply(module, function, args)
  end

  defp run(fun) when is_function(fun, 0), do: fun.()
end

defmodule Pipeline.WorkerPool do
  @moduledoc """
  Manages a bounded pool of supervised pipeline workers.

  Submitted jobs are executed immediately when a concurrency slot is free,
  or held in an in-memory queue until a running worker finishes. Finished
  workers are detected via `Process.monitor/1` so the pool stays consistent
  without periodic polling.

  The pool itself is supervised; all workers run under a separate
  `DynamicSupervisor` so crashes in individual workers do not destabilize
  the pool process.
  """

  use GenServer

  alias Pipeline.Worker

  @type opts :: [
          name: atom(),
          supervisor: atom(),
          max_concurrency: pos_integer()
        ]

  @spec start_link(opts()) :: GenServer.on_start()
  def start_link(opts) do
    name = Keyword.fetch!(opts, :name)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @spec submit(atom(), term()) :: :ok
  def submit(pool, job) when is_atom(pool) do
    GenServer.call(pool, {:submit, job})
  end

  @spec status(atom()) :: %{active: non_neg_integer(), queued: non_neg_integer()}
  def status(pool) when is_atom(pool) do
    GenServer.call(pool, :status)
  end

  @impl GenServer
  def init(opts) do
    state = %{
      supervisor: Keyword.fetch!(opts, :supervisor),
      max_concurrency: Keyword.get(opts, :max_concurrency, 10),
      active: 0,
      queue: :queue.new()
    }

    {:ok, state}
  end

  @impl GenServer
  def handle_call({:submit, job}, _from, state) do
    if state.active < state.max_concurrency do
      launch_worker(state.supervisor, job)
      {:reply, :ok, %{state | active: state.active + 1}}
    else
      {:reply, :ok, %{state | queue: :queue.in(job, state.queue)}}
    end
  end

  def handle_call(:status, _from, state) do
    {:reply, %{active: state.active, queued: :queue.len(state.queue)}, state}
  end

  @impl GenServer
  def handle_info({:DOWN, _ref, :process, _pid, _reason}, state) do
    case :queue.out(state.queue) do
      {{:value, next_job}, remaining} ->
        launch_worker(state.supervisor, next_job)
        {:noreply, %{state | queue: remaining}}

      {:empty, _} ->
        {:noreply, %{state | active: state.active - 1}}
    end
  end

  defp launch_worker(supervisor, job) do
    {:ok, pid} = DynamicSupervisor.start_child(supervisor, {Worker, job})
    Process.monitor(pid)
  end
end
```
