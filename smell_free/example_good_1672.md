```elixir
defmodule Queue.PriorityWorker do
  @moduledoc """
  A supervised GenServer that maintains three priority lanes (high, normal,
  low) for queued jobs. Workers always drain the high-priority lane first,
  ensuring latency-sensitive work is never starved by bulk tasks.
  """

  use GenServer

  @type priority :: :high | :normal | :low
  @type job :: %{id: String.t(), priority: priority(), fun: (-> {:ok, term()} | {:error, term()})}
  @type job_result :: %{id: String.t(), priority: priority(), result: {:ok, term()} | {:error, term()}}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @spec enqueue(atom() | pid(), job()) :: :ok
  def enqueue(server \\ __MODULE__, job) when is_map(job) do
    GenServer.cast(server, {:enqueue, job})
  end

  @spec queue_depths(atom() | pid()) :: %{priority() => non_neg_integer()}
  def queue_depths(server \\ __MODULE__) do
    GenServer.call(server, :depths)
  end

  @impl GenServer
  def init(opts) do
    concurrency = Keyword.get(opts, :concurrency, System.schedulers_online())
    {:ok, supervisor} = Task.Supervisor.start_link()

    state = %{
      queues: %{high: :queue.new(), normal: :queue.new(), low: :queue.new()},
      active: 0,
      concurrency: concurrency,
      supervisor: supervisor,
      results: []
    }

    {:ok, state}
  end

  @impl GenServer
  def handle_cast({:enqueue, job}, state) do
    lane = Map.get(job, :priority, :normal)
    new_queues = Map.update!(state.queues, lane, &:queue.in(job, &1))
    new_state = %{state | queues: new_queues}
    {:noreply, maybe_dispatch(new_state)}
  end

  @impl GenServer
  def handle_call(:depths, _from, state) do
    depths = Map.new(state.queues, fn {lane, q} -> {lane, :queue.len(q)} end)
    {:reply, depths, state}
  end

  @impl GenServer
  def handle_info({:job_complete, result}, state) do
    new_state = %{state | active: state.active - 1, results: [result | state.results]}
    {:noreply, maybe_dispatch(new_state)}
  end

  @spec maybe_dispatch(map()) :: map()
  defp maybe_dispatch(%{active: active, concurrency: concurrency} = state)
       when active >= concurrency do
    state
  end

  defp maybe_dispatch(state) do
    case next_job(state.queues) do
      {nil, _} ->
        state

      {job, new_queues} ->
        dispatch_job(job, state.supervisor)
        maybe_dispatch(%{state | queues: new_queues, active: state.active + 1})
    end
  end

  @spec next_job(map()) :: {job() | nil, map()}
  defp next_job(queues) do
    Enum.reduce_while([:high, :normal, :low], {nil, queues}, fn lane, {_acc_job, acc_queues} ->
      case :queue.out(acc_queues[lane]) do
        {{:value, job}, remaining} ->
          {:halt, {job, Map.put(acc_queues, lane, remaining)}}

        {:empty, _} ->
          {:cont, {nil, acc_queues}}
      end
    end)
  end

  @spec dispatch_job(job(), pid()) :: :ok
  defp dispatch_job(job, supervisor) do
    parent = self()

    Task.Supervisor.start_child(supervisor, fn ->
      result = %{id: job.id, priority: job.priority, result: job.fun.()}
      send(parent, {:job_complete, result})
    end)

    :ok
  end
end
```
