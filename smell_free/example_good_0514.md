```elixir
defmodule MyApp.Platform.PluginRegistry do
  @moduledoc """
  A supervised GenServer that maintains a runtime registry of installed
  plugins. Plugins declare their capabilities through a `Plugin` behaviour
  and are activated or deactivated without a restart. The registry stores
  plugin state per-tenant, enabling different tenants to run different
  plugin sets on the same node.

  Start this module under the application supervisor:

      children = [MyApp.Platform.PluginRegistry]
  """

  use GenServer

  require Logger

  @type tenant_id :: String.t()
  @type plugin_id :: String.t()
  @type plugin_state :: :active | :inactive | :error

  @type registration :: %{
          module: module(),
          state: plugin_state(),
          config: map(),
          activated_at: DateTime.t() | nil
        }

  @doc "Starts the plugin registry."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Registers a plugin module for `tenant_id`."
  @spec register(tenant_id(), plugin_id(), module(), map()) :: :ok
  def register(tenant_id, plugin_id, module, config \\ %{})
      when is_binary(tenant_id) and is_binary(plugin_id) and is_atom(module) do
    GenServer.call(__MODULE__, {:register, tenant_id, plugin_id, module, config})
  end

  @doc "Activates a registered plugin for `tenant_id`."
  @spec activate(tenant_id(), plugin_id()) :: :ok | {:error, :not_registered} | {:error, term()}
  def activate(tenant_id, plugin_id) when is_binary(tenant_id) and is_binary(plugin_id) do
    GenServer.call(__MODULE__, {:activate, tenant_id, plugin_id})
  end

  @doc "Deactivates an active plugin for `tenant_id`."
  @spec deactivate(tenant_id(), plugin_id()) :: :ok | {:error, :not_registered}
  def deactivate(tenant_id, plugin_id) when is_binary(tenant_id) and is_binary(plugin_id) do
    GenServer.call(__MODULE__, {:deactivate, tenant_id, plugin_id})
  end

  @doc "Returns all active plugin registrations for `tenant_id`."
  @spec active_plugins(tenant_id()) :: [{plugin_id(), registration()}]
  def active_plugins(tenant_id) when is_binary(tenant_id) do
    GenServer.call(__MODULE__, {:list_active, tenant_id})
  end

  @doc """
  Dispatches `event` to all active plugins for `tenant_id` that handle it.
  Results are collected as a map of plugin_id to handler return values.
  """
  @spec dispatch(tenant_id(), atom(), map()) :: %{plugin_id() => term()}
  def dispatch(tenant_id, event_name, payload)
      when is_binary(tenant_id) and is_atom(event_name) do
    active_plugins(tenant_id)
    |> Enum.flat_map(fn {pid, reg} ->
      if function_exported?(reg.module, :handle_event, 2) do
        result = safe_dispatch(reg.module, event_name, payload)
        [{pid, result}]
      else
        []
      end
    end)
    |> Map.new()
  end

  @impl GenServer
  def init(_opts), do: {:ok, %{plugins: %{}}}

  @impl GenServer
  def handle_call({:register, tenant_id, plugin_id, module, config}, _from, state) do
    key = {tenant_id, plugin_id}
    reg = %{module: module, state: :inactive, config: config, activated_at: nil}
    {:reply, :ok, %{state | plugins: Map.put(state.plugins, key, reg)}}
  end

  @impl GenServer
  def handle_call({:activate, tenant_id, plugin_id}, _from, state) do
    key = {tenant_id, plugin_id}
    case Map.get(state.plugins, key) do
      nil ->
        {:reply, {:error, :not_registered}, state}

      reg ->
        case safe_activate(reg.module, reg.config) do
          :ok ->
            updated = %{reg | state: :active, activated_at: DateTime.utc_now()}
            {:reply, :ok, %{state | plugins: Map.put(state.plugins, key, updated)}}

          {:error, reason} ->
            updated = %{reg | state: :error}
            {:reply, {:error, reason}, %{state | plugins: Map.put(state.plugins, key, updated)}}
        end
    end
  end

  @impl GenServer
  def handle_call({:deactivate, tenant_id, plugin_id}, _from, state) do
    key = {tenant_id, plugin_id}
    case Map.get(state.plugins, key) do
      nil ->
        {:reply, {:error, :not_registered}, state}

      reg ->
        safe_deactivate(reg.module)
        updated = %{reg | state: :inactive, activated_at: nil}
        {:reply, :ok, %{state | plugins: Map.put(state.plugins, key, updated)}}
    end
  end

  @impl GenServer
  def handle_call({:list_active, tenant_id}, _from, state) do
    active =
      state.plugins
      |> Enum.filter(fn {{tid, _}, reg} -> tid == tenant_id and reg.state == :active end)
      |> Enum.map(fn {{_tid, pid}, reg} -> {pid, reg} end)

    {:reply, active, state}
  end

  @spec safe_activate(module(), map()) :: :ok | {:error, term()}
  defp safe_activate(module, config) do
    module.on_activate(config)
  rescue
    e -> {:error, Exception.message(e)}
  end

  @spec safe_deactivate(module()) :: :ok
  defp safe_deactivate(module) do
    module.on_deactivate()
  rescue
    _ -> :ok
  end

  @spec safe_dispatch(module(), atom(), map()) :: term()
  defp safe_dispatch(module, event_name, payload) do
    module.handle_event(event_name, payload)
  rescue
    e ->
      Logger.warning("plugin_dispatch_failed", module: module, event: event_name, error: Exception.message(e))
      {:error, :dispatch_failed}
  end
end
```
