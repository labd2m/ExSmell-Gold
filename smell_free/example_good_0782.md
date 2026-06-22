```elixir
defmodule Processing.TenantWorker do
  @moduledoc """
  A supervised GenServer that processes domain jobs for a single tenant.
  Each tenant gets exactly one worker process, started on-demand by the
  `TenantWorkerSupervisor` and registered under the tenant ID in a
  dedicated Registry. Jobs are queued in-process and processed sequentially
  to preserve per-tenant ordering guarantees. Completed and failed job
  outcomes are persisted before the next job is dequeued.
  """

  use GenServer

  alias Processing.{Job, JobStore}

  require Logger

  @type tenant_id :: binary()
  @idle_shutdown_ms 10 * 60 * 1_000

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    tenant_id = Keyword.fetch!(opts, :tenant_id)
    GenServer.start_link(__MODULE__, opts, name: via(tenant_id))
  end

  @doc """
  Enqueues `job` for processing by the worker for `tenant_id`.
  Starts the worker if it is not already running.
  Returns `:ok` or `{:error, reason}`.
  """
  @spec enqueue(tenant_id(), Job.t()) :: :ok | {:error, term()}
  def enqueue(tenant_id, %Job{} = job) when is_binary(tenant_id) do
    ensure_started(tenant_id)
    GenServer.cast(via(tenant_id), {:enqueue, job})
  end

  @doc """
  Returns the current queue depth for `tenant_id`.
  Returns `0` when no worker is running for the tenant.
  """
  @spec queue_depth(tenant_id()) :: non_neg_integer()
  def queue_depth(tenant_id) when is_binary(tenant_id) do
    case Registry.lookup(Processing.WorkerRegistry, tenant_id) do
      [{pid, _}] -> GenServer.call(pid, :queue_depth)
      [] -> 0
    end
  end

  # ---------------------------------------------------------------------------
  # GenServer callbacks
  # ---------------------------------------------------------------------------

  @impl GenServer
  def init(opts) do
    tenant_id = Keyword.fetch!(opts, :tenant_id)
    schedule_idle_check()

    {:ok, %{tenant_id: tenant_id, queue: :queue.new(), processing: false}}
  end

  @impl GenServer
  def handle_cast({:enqueue, job}, state) do
    new_queue = :queue.in(job, state.queue)
    new_state = %{state | queue: new_queue}

    if state.processing do
      {:noreply, new_state}
    else
      {:noreply, process_next(new_state)}
    end
  end

  @impl GenServer
  def handle_call(:queue_depth, _from, state) do
    {:reply, :queue.len(state.queue), state}
  end

  @impl GenServer
  def handle_info({:job_done, result, job}, state) do
    persist_outcome(job, result, state.tenant_id)
    new_state = %{state | processing: false}

    if :queue.is_empty(new_state.queue) do
      {:noreply, new_state}
    else
      {:noreply, process_next(new_state)}
    end
  end

  def handle_info(:idle_check, %{queue: q, processing: false} = state) do
    if :queue.is_empty(q) do
      Logger.info("Tenant worker idle, shutting down", tenant_id: state.tenant_id)
      {:stop, :normal, state}
    else
      schedule_idle_check()
      {:noreply, state}
    end
  end

  def handle_info(:idle_check, state) do
    schedule_idle_check()
    {:noreply, state}
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp process_next(%{queue: q} = state) do
    case :queue.out(q) do
      {:empty, _} ->
        state

      {{:value, job}, rest} ->
        parent = self()

        Task.start(fn ->
          result = JobStore.execute(job)
          send(parent, {:job_done, result, job})
        end)

        %{state | queue: rest, processing: true}
    end
  end

  defp persist_outcome(job, {:ok, _} = result, tenant_id) do
    Logger.debug("Job succeeded", tenant_id: tenant_id, job_id: job.id)
    JobStore.mark_done(job, result)
  end

  defp persist_outcome(job, {:error, reason}, tenant_id) do
    Logger.warning("Job failed", tenant_id: tenant_id, job_id: job.id, reason: inspect(reason))
    JobStore.mark_failed(job, reason)
  end

  defp ensure_started(tenant_id) do
    case Processing.TenantWorkerSupervisor.ensure_worker(tenant_id) do
      {:ok, _pid} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp schedule_idle_check do
    Process.send_after(self(), :idle_check, @idle_shutdown_ms)
  end

  defp via(tenant_id) do
    {:via, Registry, {Processing.WorkerRegistry, tenant_id}}
  end
end

defmodule Processing.TenantWorkerSupervisor do
  @moduledoc """
  DynamicSupervisor that manages one `TenantWorker` per tenant.
  """

  use DynamicSupervisor

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    DynamicSupervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec ensure_worker(Processing.TenantWorker.tenant_id()) :: {:ok, pid()} | {:error, term()}
  def ensure_worker(tenant_id) when is_binary(tenant_id) do
    spec = {Processing.TenantWorker, tenant_id: tenant_id}

    case DynamicSupervisor.start_child(__MODULE__, spec) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl DynamicSupervisor
  def init(_opts) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end
end
```
