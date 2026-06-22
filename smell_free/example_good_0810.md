```elixir
defmodule MyApp.Platform.PluginHostSupervisor do
  @moduledoc """
  A `DynamicSupervisor` that hosts per-plugin worker processes. Each
  active plugin for each tenant is started as a supervised child. If a
  plugin process crashes it is restarted automatically without affecting
  other plugins or tenants. Plugins declare their supervision spec via
  the `child_spec/1` callback.

  The host supervisor is started under the application supervisor and
  exposes a clean API for activating and deactivating individual plugins
  at runtime.
  """

  use DynamicSupervisor

  require Logger

  @type tenant_id :: String.t()
  @type plugin_id :: String.t()

  @doc "Starts the plugin host supervisor."
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    DynamicSupervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Starts a supervised plugin process for `tenant_id` / `plugin_id`.
  Returns `{:error, :already_running}` when the plugin is already active.
  """
  @spec activate(tenant_id(), plugin_id(), module(), map()) ::
          {:ok, pid()} | {:error, :already_running} | {:error, term()}
  def activate(tenant_id, plugin_id, module, config \\ %{})
      when is_binary(tenant_id) and is_binary(plugin_id) do
    name = via(tenant_id, plugin_id)

    case Registry.lookup(MyApp.Platform.PluginRegistry, {tenant_id, plugin_id}) do
      [{_pid, _}] ->
        {:error, :already_running}

      [] ->
        child_spec = module.child_spec(%{
          tenant_id: tenant_id,
          plugin_id: plugin_id,
          config: config,
          name: name
        })

        case DynamicSupervisor.start_child(__MODULE__, child_spec) do
          {:ok, pid} ->
            Logger.info("plugin_activated", tenant_id: tenant_id, plugin_id: plugin_id)
            {:ok, pid}

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  @doc """
  Stops the plugin process for `tenant_id` / `plugin_id`.
  Returns `{:error, :not_running}` when the plugin is not active.
  """
  @spec deactivate(tenant_id(), plugin_id()) :: :ok | {:error, :not_running}
  def deactivate(tenant_id, plugin_id) when is_binary(tenant_id) and is_binary(plugin_id) do
    case Registry.lookup(MyApp.Platform.PluginRegistry, {tenant_id, plugin_id}) do
      [{pid, _}] ->
        DynamicSupervisor.terminate_child(__MODULE__, pid)
        Logger.info("plugin_deactivated", tenant_id: tenant_id, plugin_id: plugin_id)
        :ok

      [] ->
        {:error, :not_running}
    end
  end

  @doc "Returns the pids of all currently running plugin processes."
  @spec running_plugins() :: [{tenant_id(), plugin_id(), pid()}]
  def running_plugins do
    Registry.select(MyApp.Platform.PluginRegistry, [
      {{{:"$1", :"$2"}, :"$3", :_}, [], [{{:"$1", :"$2", :"$3"}}]}
    ])
    |> Enum.map(fn {tenant_id, plugin_id, pid} -> {tenant_id, plugin_id, pid} end)
  end

  @doc "Returns the count of active plugin processes across all tenants."
  @spec active_count() :: non_neg_integer()
  def active_count do
    __MODULE__
    |> DynamicSupervisor.which_children()
    |> length()
  end

  @impl DynamicSupervisor
  def init(_opts) do
    DynamicSupervisor.init(strategy: :one_for_one, max_restarts: 10, max_seconds: 60)
  end

  @spec via(tenant_id(), plugin_id()) ::
          {:via, Registry, {MyApp.Platform.PluginRegistry, {tenant_id(), plugin_id()}}}
  defp via(tenant_id, plugin_id) do
    {:via, Registry, {MyApp.Platform.PluginRegistry, {tenant_id, plugin_id}}}
  end
end
```
