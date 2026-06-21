# File: `example_good_20.md`

```elixir
defmodule Jobs.WorkerSupervisor do
  @moduledoc """
  DynamicSupervisor that manages a pool of supervised job worker processes.

  Workers are started on demand for each dequeued job and terminated
  automatically upon completion or permanent failure. The supervisor
  enforces a maximum concurrency cap to prevent resource exhaustion
  under high load.
  """

  use DynamicSupervisor

  require Logger

  alias Jobs.Worker

  @max_concurrency 50

  @type job :: %{
          required(:id) => String.t(),
          required(:type) => atom(),
          required(:payload) => map()
        }

  @type start_result ::
          {:ok, pid()}
          | {:error, :at_capacity}
          | DynamicSupervisor.on_start_child()

  @doc false
  def start_link(opts \\ []) do
    DynamicSupervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl DynamicSupervisor
  def init(_opts) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  @doc """
  Starts a supervised worker to process the given job.

  Returns `{:error, :at_capacity}` when the number of active workers
  has reached the configured maximum, preventing unbounded growth.
  """
  @spec start_worker(job()) :: start_result()
  def start_worker(%{id: id, type: type, payload: payload} = job)
      when is_binary(id) and is_atom(type) and is_map(payload) do
    if at_capacity?() do
      Logger.warning("Job supervisor at capacity, rejecting job #{id}")
      {:error, :at_capacity}
    else
      DynamicSupervisor.start_child(__MODULE__, {Worker, job})
    end
  end

  @doc """
  Returns the number of workers currently running under this supervisor.
  """
  @spec active_count() :: non_neg_integer()
  def active_count do
    count_active_children()
  end

  @doc """
  Returns summary statistics for this supervisor.
  """
  @spec stats() :: map()
  def stats do
    %DynamicSupervisor.Count{
      active: active,
      specs: specs,
      supervisors: supervisors,
      workers: workers
    } = DynamicSupervisor.count_children(__MODULE__)

    %{
      active: active,
      specs: specs,
      supervisors: supervisors,
      workers: workers,
      capacity: @max_concurrency,
      available: max(@max_concurrency - active, 0)
    }
  end

  @doc """
  Terminates a worker by PID.

  Returns `:ok` on success or `{:error, :not_found}` if the PID is
  not a child of this supervisor.
  """
  @spec terminate_worker(pid()) :: :ok | {:error, :not_found}
  def terminate_worker(pid) when is_pid(pid) do
    case DynamicSupervisor.terminate_child(__MODULE__, pid) do
      :ok -> :ok
      {:error, :not_found} -> {:error, :not_found}
    end
  end

  @doc """
  Lists all active worker PIDs and their associated job IDs.

  Workers that have terminated since the list was fetched are excluded.
  """
  @spec list_workers() :: [%{pid: pid(), job_id: String.t()}]
  def list_workers do
    __MODULE__
    |> DynamicSupervisor.which_children()
    |> Enum.flat_map(&resolve_worker_info/1)
  end

  defp at_capacity? do
    count_active_children() >= @max_concurrency
  end

  defp count_active_children do
    %DynamicSupervisor.Count{active: active} =
      DynamicSupervisor.count_children(__MODULE__)

    active
  end

  defp resolve_worker_info({_id, pid, :worker, _modules}) when is_pid(pid) do
    case Worker.current_job_id(pid) do
      {:ok, job_id} -> [%{pid: pid, job_id: job_id}]
      {:error, _} -> []
    end
  end

  defp resolve_worker_info(_child), do: []
end
```
