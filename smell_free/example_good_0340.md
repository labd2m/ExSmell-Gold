```elixir
defmodule Platform.TenantSupervisor do
  @moduledoc """
  A top-level DynamicSupervisor that provisions and tears down an isolated
  supervision sub-tree for each active tenant.

  Each tenant sub-tree groups all long-running processes scoped to that
  tenant (caches, background workers, sessions) under a dedicated
  supervisor, ensuring a tenant lifecycle event (e.g. suspension) cleanly
  stops all its processes without affecting other tenants.
  """

  use DynamicSupervisor

  alias Platform.TenantSupervisor.TenantSubtree

  @type tenant_id :: pos_integer()

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    DynamicSupervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl DynamicSupervisor
  def init(_opts) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  @doc """
  Starts the supervision sub-tree for `tenant_id` if not already running.
  Returns `{:ok, pid}` or `{:error, {:already_started, pid}}`.
  """
  @spec start_tenant(tenant_id()) :: {:ok, pid()} | {:error, term()}
  def start_tenant(tenant_id) when is_integer(tenant_id) do
    spec = {TenantSubtree, tenant_id: tenant_id}
    DynamicSupervisor.start_child(__MODULE__, spec)
  end

  @doc """
  Stops and removes the sub-tree for `tenant_id`.
  Returns `:ok` if the tenant was running, `{:error, :not_found}` otherwise.
  """
  @spec stop_tenant(tenant_id()) :: :ok | {:error, :not_found}
  def stop_tenant(tenant_id) when is_integer(tenant_id) do
    case find_tenant_pid(tenant_id) do
      {:ok, pid} -> DynamicSupervisor.terminate_child(__MODULE__, pid)
      {:error, :not_found} -> {:error, :not_found}
    end
  end

  @doc "Returns the pid of the sub-tree supervisor for `tenant_id`."
  @spec find_tenant_pid(tenant_id()) :: {:ok, pid()} | {:error, :not_found}
  def find_tenant_pid(tenant_id) do
    case Registry.lookup(Platform.TenantRegistry, tenant_id) do
      [{pid, _}] -> {:ok, pid}
      [] -> {:error, :not_found}
    end
  end

  @doc "Returns the ids of all currently active tenants."
  @spec active_tenant_ids() :: [tenant_id()]
  def active_tenant_ids do
    Registry.select(Platform.TenantRegistry, [{{:"$1", :_, :_}, [], [:"$1"]}])
  end
end

defmodule Platform.TenantSupervisor.TenantSubtree do
  @moduledoc """
  A one-for-one Supervisor that owns all processes for a single tenant.

  Registers itself in `Platform.TenantRegistry` under the tenant id for
  external discovery. Extend `children/1` to add tenant-scoped workers.
  """

  use Supervisor

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts) do
    tenant_id = Keyword.fetch!(opts, :tenant_id)
    Supervisor.start_link(__MODULE__, opts, name: via(tenant_id))
  end

  @impl Supervisor
  def init(opts) do
    tenant_id = Keyword.fetch!(opts, :tenant_id)
    {:ok, _} = Registry.register(Platform.TenantRegistry, tenant_id, %{started_at: DateTime.utc_now()})

    children = tenant_children(tenant_id)
    Supervisor.init(children, strategy: :one_for_one)
  end

  defp tenant_children(tenant_id) do
    [
      {Platform.TenantCache, tenant_id: tenant_id, name: cache_name(tenant_id)},
      {Platform.TenantEventHandler, tenant_id: tenant_id, name: handler_name(tenant_id)}
    ]
  end

  defp cache_name(tenant_id), do: :"tenant_cache_#{tenant_id}"
  defp handler_name(tenant_id), do: :"tenant_event_handler_#{tenant_id}"

  defp via(tenant_id) do
    {:via, Registry, {Platform.TenantRegistry, {:supervisor, tenant_id}}}
  end
end
```
