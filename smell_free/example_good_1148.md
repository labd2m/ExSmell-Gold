```elixir
defmodule Pipeline.WorkerSupervisor do
  @moduledoc """
  Dynamic supervisor managing transient pipeline worker processes.

  Workers are started on demand and terminate themselves after completing
  their assigned job. The supervisor enforces a maximum concurrency limit
  to prevent resource exhaustion during traffic spikes.
  """
  use DynamicSupervisor

  @max_children 50

  @doc "Starts the worker supervisor linked to the application supervision tree."
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    DynamicSupervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Dispatches a supervised worker for the given job map.

  Returns `{:error, :max_children}` when the concurrency ceiling is reached.
  """
  @spec dispatch(map()) :: {:ok, pid()} | {:error, term()}
  def dispatch(job) when is_map(job) do
    DynamicSupervisor.start_child(__MODULE__, {Pipeline.Worker, job})
  end

  @doc "Returns the count of currently active worker processes."
  @spec active_count() :: non_neg_integer()
  def active_count do
    __MODULE__
    |> DynamicSupervisor.which_children()
    |> length()
  end

  @impl DynamicSupervisor
  def init(_opts) do
    DynamicSupervisor.init(strategy: :one_for_one, max_children: @max_children)
  end
end

defmodule Pipeline.Worker do
  @moduledoc """
  Transient GenServer that processes a single pipeline job then stops normally.

  Errors during execution are logged with structured metadata and do not
  propagate to the supervisor, since each job is an independent unit of work.
  """
  use GenServer, restart: :transient

  require Logger

  @type job :: %{
          required(:id) => String.t(),
          required(:type) => String.t(),
          required(:payload) => map()
        }

  @doc "Starts a worker for the given job. Called by the dynamic supervisor."
  @spec start_link(job()) :: GenServer.on_start()
  def start_link(job) when is_map(job) do
    GenServer.start_link(__MODULE__, job)
  end

  @impl GenServer
  def init(job) do
    send(self(), :execute)
    {:ok, job}
  end

  @impl GenServer
  def handle_info(:execute, job) do
    job
    |> run_job()
    |> record_outcome(job)

    {:stop, :normal, job}
  end

  # ── Private helpers ───────────────────────────────────────────────────────────

  defp run_job(%{type: "transform", payload: payload}), do: Pipeline.Transformers.run(payload)
  defp run_job(%{type: "export", payload: payload}), do: Pipeline.Exporters.run(payload)
  defp run_job(%{type: "notify", payload: payload}), do: Pipeline.Notifiers.run(payload)

  defp run_job(%{type: unknown_type}) do
    {:error, {:unsupported_job_type, unknown_type}}
  end

  defp record_outcome({:ok, _}, %{id: id, type: type}) do
    Logger.info("Pipeline job succeeded", job_id: id, type: type)
  end

  defp record_outcome({:error, reason}, %{id: id, type: type}) do
    Logger.error("Pipeline job failed", job_id: id, type: type, reason: inspect(reason))
  end
end
```
