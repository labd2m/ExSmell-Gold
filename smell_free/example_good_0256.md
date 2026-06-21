```elixir
defmodule Ingestion.TenantSupervisor do
  @moduledoc """
  A `DynamicSupervisor` that manages one `Ingestion.Worker` process per
  tenant. Workers are started on-demand and restarted automatically on
  failure. The supervisor exposes an explicit API to start, stop, and
  inspect workers so no caller ever manipulates processes directly.
  """

  use DynamicSupervisor

  alias Ingestion.Worker

  @type tenant_id :: binary()

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @doc """
  Starts the `TenantSupervisor` and links it to the calling process.
  Intended to be added as a child of the application's root supervisor.
  """
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    DynamicSupervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Ensures an ingestion worker is running for `tenant_id`.
  Returns `{:ok, pid}` whether the worker was freshly started or already
  alive. Returns `{:error, reason}` if the worker could not be started.
  """
  @spec ensure_worker(tenant_id()) :: {:ok, pid()} | {:error, term()}
  def ensure_worker(tenant_id) when is_binary(tenant_id) do
    case find_worker(tenant_id) do
      {:ok, pid} -> {:ok, pid}
      :not_found -> start_worker(tenant_id)
    end
  end

  @doc """
  Gracefully stops the worker for the given tenant, allowing it to flush
  any buffered data before terminating.
  Returns `:ok` if the worker was stopped, `{:error, :not_found}` if none
  was running.
  """
  @spec stop_worker(tenant_id()) :: :ok | {:error, :not_found}
  def stop_worker(tenant_id) when is_binary(tenant_id) do
    case find_worker(tenant_id) do
      {:ok, pid} ->
        DynamicSupervisor.terminate_child(__MODULE__, pid)
        :ok

      :not_found ->
        {:error, :not_found}
    end
  end

  @doc """
  Returns a map of `%{tenant_id => pid}` for all currently running workers.
  """
  @spec running_workers() :: %{tenant_id() => pid()}
  def running_workers do
    DynamicSupervisor.which_children(__MODULE__)
    |> Enum.flat_map(&resolve_tenant_pid/1)
    |> Map.new()
  end

  @doc """
  Returns `true` if a worker is currently active for `tenant_id`.
  """
  @spec worker_alive?(tenant_id()) :: boolean()
  def worker_alive?(tenant_id) when is_binary(tenant_id) do
    match?({:ok, _pid}, find_worker(tenant_id))
  end

  # ---------------------------------------------------------------------------
  # DynamicSupervisor callback
  # ---------------------------------------------------------------------------

  @impl DynamicSupervisor
  def init(_opts) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp start_worker(tenant_id) do
    child_spec = Worker.child_spec(tenant_id: tenant_id)

    case DynamicSupervisor.start_child(__MODULE__, child_spec) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
      {:error, reason} -> {:error, reason}
    end
  end

  defp find_worker(tenant_id) do
    case Registry.lookup(Ingestion.WorkerRegistry, tenant_id) do
      [{pid, _}] when is_pid(pid) -> {:ok, pid}
      [] -> :not_found
    end
  end

  defp resolve_tenant_pid({_id, pid, _type, _modules}) when is_pid(pid) do
    case Worker.tenant_id(pid) do
      {:ok, tenant_id} -> [{tenant_id, pid}]
      _ -> []
    end
  end

  defp resolve_tenant_pid(_), do: []
end
```
