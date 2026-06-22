```elixir
defmodule Workers.BoundedPool do
  @moduledoc """
  A supervised bounded worker pool backed by a DynamicSupervisor and a
  demand-driven checkout queue. Callers block until a worker slot is
  available or a timeout elapses, providing natural backpressure without
  dropping work silently.
  """

  use GenServer

  @type job :: (-> {:ok, term()} | {:error, term()})
  @type submit_result :: {:ok, term()} | {:error, :timeout | :worker_failed | term()}

  @default_timeout_ms 10_000

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @spec submit(atom() | pid(), job(), keyword()) :: submit_result()
  def submit(pool, job, opts \\ []) when is_function(job, 0) do
    timeout = Keyword.get(opts, :timeout, @default_timeout_ms)
    GenServer.call(pool, {:submit, job}, timeout)
  catch
    :exit, {:timeout, _} -> {:error, :timeout}
  end

  @spec pool_stats(atom() | pid()) :: %{
          active: non_neg_integer(),
          queued: non_neg_integer(),
          capacity: pos_integer()
        }
  def pool_stats(pool) do
    GenServer.call(pool, :stats)
  end

  @impl GenServer
  def init(opts) do
    capacity = Keyword.get(opts, :capacity, System.schedulers_online() * 2)

    {:ok, supervisor} =
      DynamicSupervisor.start_link(strategy: :one_for_one)

    {:ok,
     %{
       supervisor: supervisor,
       capacity: capacity,
       active: 0,
       queue: :queue.new()
     }}
  end

  @impl GenServer
  def handle_call({:submit, job}, from, %{active: active, capacity: capacity} = state)
      when active < capacity do
    updated = %{state | active: active + 1}
    dispatch(job, from, updated.supervisor)
    {:noreply, updated}
  end

  def handle_call({:submit, job}, from, state) do
    updated = Map.update!(state, :queue, &:queue.in({job, from}, &1))
    {:noreply, updated}
  end

  def handle_call(:stats, _from, state) do
    stats = %{
      active: state.active,
      queued: :queue.len(state.queue),
      capacity: state.capacity
    }

    {:reply, stats, state}
  end

  @impl GenServer
  def handle_info({:job_done, result, from}, state) do
    GenServer.reply(from, result)
    dequeue_next(%{state | active: state.active - 1})
  end

  @spec dequeue_next(map()) :: {:noreply, map()}
  defp dequeue_next(%{queue: queue, supervisor: supervisor} = state) do
    case :queue.out(queue) do
      {{:value, {job, from}}, remaining_queue} ->
        updated = %{state | active: state.active + 1, queue: remaining_queue}
        dispatch(job, from, supervisor)
        {:noreply, updated}

      {:empty, _} ->
        {:noreply, state}
    end
  end

  @spec dispatch(job(), GenServer.from(), pid()) :: :ok
  defp dispatch(job, from, supervisor) do
    caller = self()

    DynamicSupervisor.start_child(supervisor, %{
      id: make_ref(),
      start:
        {Task, :start_link,
         [
           fn ->
             result =
               try do
                 job.()
               rescue
                 e -> {:error, {:worker_failed, e}}
               end

             send(caller, {:job_done, result, from})
           end
         ]},
      restart: :temporary
    })

    :ok
  end
end
```
