```elixir
defmodule Workers.Supervisor do
  @moduledoc """
  Supervises a dynamic pool of task worker processes.
  Workers are started on demand and removed from the pool once their work completes.
  The supervisor uses a one-for-one strategy so individual worker failures
  do not affect sibling processes.
  """

  use DynamicSupervisor

  @doc "Starts the dynamic supervisor and links it to the calling process."
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    DynamicSupervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Spawns a supervised worker process to handle the given job."
  @spec start_worker(map()) :: DynamicSupervisor.on_start_child()
  def start_worker(job) when is_map(job) do
    DynamicSupervisor.start_child(__MODULE__, {Workers.JobWorker, job})
  end

  @impl DynamicSupervisor
  def init(_opts) do
    DynamicSupervisor.init(strategy: :one_for_one, max_children: 200)
  end
end

defmodule Workers.JobWorker do
  @moduledoc """
  A temporary GenServer representing a single in-flight job.
  The worker terminates normally upon job completion or on a controlled error,
  reporting the outcome before stopping.
  """

  use GenServer, restart: :temporary

  @type job :: %{id: String.t(), type: atom(), payload: map()}

  @doc "Starts a job worker linked to its supervisor."
  @spec start_link(job()) :: GenServer.on_start()
  def start_link(%{id: id} = job) when is_binary(id) do
    GenServer.start_link(__MODULE__, job)
  end

  @impl GenServer
  def init(job) do
    send(self(), :execute)
    {:ok, job}
  end

  @impl GenServer
  def handle_info(:execute, job) do
    result = execute_job(job)
    report_result(job.id, result)
    {:stop, :normal, job}
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp execute_job(%{type: :email_dispatch, payload: payload}) do
    Mailer.deliver(payload.to, payload.subject, payload.body)
  end

  defp execute_job(%{type: :report_export, payload: payload}) do
    Reports.Export.run(payload.report_id, payload.format)
  end

  defp execute_job(%{type: unknown_type}) do
    {:error, {:unsupported_job_type, unknown_type}}
  end

  defp report_result(job_id, {:ok, _result}) do
    Jobs.Registry.mark_complete(job_id)
  end

  defp report_result(job_id, {:error, reason}) do
    Jobs.Registry.mark_failed(job_id, reason)
  end
end
```
