```elixir
defmodule Platform.WorkStealingPool do
  @moduledoc """
  A distributed work-stealing task pool where idle workers pull jobs from
  the queues of busy workers, maximising throughput under uneven load.

  Each worker maintains a local double-ended queue (deque). Workers push and
  pop from their own deque's front. When a worker runs out of local work it
  steals from the back of a random peer's deque, minimising contention.
  """

  use Supervisor

  alias Platform.WorkStealingPool.Worker

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl Supervisor
  def init(opts) do
    worker_count = Keyword.get(opts, :workers, System.schedulers_online())

    children =
      for id <- 1..worker_count do
        Supervisor.child_spec({Worker, worker_id: id, pool_size: worker_count},
          id: {Worker, id}
        )
      end

    Supervisor.init(children, strategy: :one_for_one)
  end

  @doc "Submits a job to the pool. The job is placed on the least-loaded worker's queue."
  @spec submit((-> term())) :: :ok
  def submit(fun) when is_function(fun, 0) do
    worker = least_loaded_worker()
    Worker.push(worker, fun)
  end

  defp least_loaded_worker do
    1..worker_count()
    |> Enum.min_by(&Worker.queue_depth(worker_name(&1)))
    |> worker_name()
  end

  defp worker_count do
    __MODULE__
    |> Supervisor.which_children()
    |> length()
  end

  defp worker_name(id), do: :"work_stealing_worker_#{id}"
end

defmodule Platform.WorkStealingPool.Worker do
  @moduledoc """
  A worker process that executes jobs from its local deque and steals
  from peers when idle.
  """

  use GenServer

  require Logger

  @steal_interval_ms 5
  @idle_timeout_ms 50

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    id = Keyword.fetch!(opts, :worker_id)
    GenServer.start_link(__MODULE__, opts, name: :"work_stealing_worker_#{id}")
  end

  @doc "Pushes a job to the front of this worker's deque."
  @spec push(atom(), (-> term())) :: :ok
  def push(worker, fun), do: GenServer.cast(worker, {:push, fun})

  @doc "Returns the current number of jobs in this worker's queue."
  @spec queue_depth(atom()) :: non_neg_integer()
  def queue_depth(worker), do: GenServer.call(worker, :depth)

  @impl GenServer
  def init(opts) do
    worker_id = Keyword.fetch!(opts, :worker_id)
    pool_size = Keyword.fetch!(opts, :pool_size)
    send(self(), :run)
    {:ok, %{id: worker_id, pool_size: pool_size, deque: :queue.new(), running: 0}}
  end

  @impl GenServer
  def handle_cast({:push, fun}, state) do
    {:noreply, %{state | deque: :queue.in_r(fun, state.deque)}}
  end

  @impl GenServer
  def handle_call(:depth, _from, state) do
    {:reply, :queue.len(state.deque), state}
  end

  @impl GenServer
  def handle_info(:run, state) do
    case :queue.out(state.deque) do
      {{:value, fun}, rest} ->
        execute_job(fun)
        send(self(), :run)
        {:noreply, %{state | deque: rest}}

      {:empty, _} ->
        case attempt_steal(state) do
          {:ok, fun, new_state} ->
            execute_job(fun)
            send(self(), :run)
            {:noreply, new_state}

          :nothing_to_steal ->
            Process.send_after(self(), :run, @idle_timeout_ms)
            {:noreply, state}
        end
    end
  end

  defp execute_job(fun) do
    Task.start(fn ->
      try do
        fun.()
      rescue
        error -> Logger.error("[WorkStealingPool] Job failed", error: inspect(error))
      end
    end)
  end

  defp attempt_steal(%{id: my_id, pool_size: size} = state) do
    peer_ids = 1..size |> Enum.reject(&(&1 == my_id)) |> Enum.shuffle()

    Enum.find_value(peer_ids, :nothing_to_steal, fn peer_id ->
      peer = :"work_stealing_worker_#{peer_id}"
      case GenServer.call(peer, :steal, 100) do
        {:ok, fun} -> {:ok, fun, state}
        :empty -> nil
      end
    end)
  end

  @impl GenServer
  def handle_call(:steal, _from, state) do
    case :queue.out_r(state.deque) do
      {{:value, fun}, rest} -> {:reply, {:ok, fun}, %{state | deque: rest}}
      {:empty, _} -> {:reply, :empty, state}
    end
  end
end
```
