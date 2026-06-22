```elixir
defmodule WorkerPool.Supervisor do
  @moduledoc """
  Dynamic supervision tree for short-lived, domain-scoped job workers.

  Each worker is started under a `DynamicSupervisor` with a one-for-one
  strategy, ensuring independent crash isolation per job. Workers are
  registered by job ID to prevent duplicate execution.
  """

  use Supervisor

  alias WorkerPool.JobWorker

  @registry WorkerPool.Registry

  @doc """
  Starts the pool supervisor and its supporting registry as a linked process.
  """
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Dispatches a new worker for the given job, identified by a unique job ID.

  Returns `{:error, :already_running}` if a worker for the given job is
  already active in the registry.
  """
  @spec dispatch(String.t(), map()) ::
          {:ok, pid()} | {:error, :already_running} | {:error, term()}
  def dispatch(job_id, payload) when is_binary(job_id) and is_map(payload) do
    case Registry.lookup(@registry, job_id) do
      [{_pid, _}] ->
        {:error, :already_running}

      [] ->
        DynamicSupervisor.start_child(
          WorkerPool.DynamicSupervisor,
          {JobWorker, job_id: job_id, payload: payload}
        )
    end
  end

  @doc """
  Returns the PIDs of all currently running workers.
  """
  @spec running_workers() :: [pid()]
  def running_workers do
    DynamicSupervisor.which_children(WorkerPool.DynamicSupervisor)
    |> Enum.map(fn {_, pid, _, _} -> pid end)
    |> Enum.filter(&is_pid/1)
  end

  @impl Supervisor
  def init(_opts) do
    children = [
      {Registry, keys: :unique, name: @registry},
      {DynamicSupervisor, name: WorkerPool.DynamicSupervisor, strategy: :one_for_one}
    ]

    Supervisor.init(children, strategy: :one_for_all)
  end
end

defmodule WorkerPool.JobWorker do
  @moduledoc """
  A supervised GenServer responsible for executing a single scoped job payload.

  Registers itself in the pool registry upon startup and terminates cleanly
  after job completion or on an unrecoverable processing error.
  """

  use GenServer, restart: :temporary

  require Logger

  @registry WorkerPool.Registry

  @type job_opts :: [job_id: String.t(), payload: map()]

  @doc false
  @spec start_link(job_opts()) :: GenServer.on_start()
  def start_link(opts) do
    job_id = Keyword.fetch!(opts, :job_id)
    GenServer.start_link(__MODULE__, opts, name: via(job_id))
  end

  @impl GenServer
  def init(opts) do
    job_id = Keyword.fetch!(opts, :job_id)
    payload = Keyword.fetch!(opts, :payload)
    send(self(), :execute)
    {:ok, %{job_id: job_id, payload: payload}}
  end

  @impl GenServer
  def handle_info(:execute, %{job_id: job_id, payload: payload} = state) do
    Logger.info("[JobWorker] Starting job", job_id: job_id)

    case run_job(payload) do
      {:ok, result} ->
        Logger.info("[JobWorker] Completed job", job_id: job_id, result: inspect(result))
        {:stop, :normal, state}

      {:error, reason} ->
        Logger.error("[JobWorker] Failed job", job_id: job_id, reason: inspect(reason))
        {:stop, {:job_failed, reason}, state}
    end
  end

  defp run_job(%{type: "export", resource: resource, format: format}) do
    WorkerPool.Exporters.export(resource, format)
  end

  defp run_job(%{type: "notify", channel: channel, message: message}) do
    WorkerPool.Notifiers.send_notification(channel, message)
  end

  defp run_job(payload) do
    Logger.warning("[JobWorker] Unrecognized payload type", payload: inspect(payload))
    {:error, :unknown_job_type}
  end

  defp via(job_id) do
    {:via, Registry, {@registry, job_id}}
  end
end
```
