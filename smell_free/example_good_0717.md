```elixir
defmodule Platform.PluginSystem do
  @moduledoc """
  A registry-based plugin system supporting dynamic registration,
  lifecycle hooks, and ordered dispatch across registered plugins.

  Plugins implement the `Platform.Plugin` behaviour. The system calls
  hooks in priority order (lower number = higher priority), collecting
  results from all plugins per hook invocation.
  """

  use GenServer

  alias Platform.Plugin

  @type plugin_name :: atom()
  @type hook :: atom()
  @type priority :: non_neg_integer()
  @type plugin_entry :: %{name: plugin_name(), module: module(), priority: priority()}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Registers a plugin module under `name` with an optional `priority`.
  Calls the plugin's `on_register/0` hook if implemented.
  """
  @spec register(plugin_name(), module(), priority()) :: :ok | {:error, :already_registered}
  def register(name, module, priority \\ 100)
      when is_atom(name) and is_atom(module) and is_integer(priority) do
    GenServer.call(__MODULE__, {:register, name, module, priority})
  end

  @doc "Unregisters a plugin by name. Calls the plugin's `on_unregister/0` hook."
  @spec unregister(plugin_name()) :: :ok | {:error, :not_found}
  def unregister(name) when is_atom(name) do
    GenServer.call(__MODULE__, {:unregister, name})
  end

  @doc """
  Invokes `hook` on all registered plugins in priority order.
  Each plugin's result is collected into a keyword list `[plugin_name: result]`.
  """
  @spec dispatch(hook(), term()) :: keyword()
  def dispatch(hook, payload \\ nil) when is_atom(hook) do
    plugins = GenServer.call(__MODULE__, :list)
    Enum.map(plugins, fn %{name: name, module: module} ->
      result = if function_exported?(module, hook, 1) do
        apply(module, hook, [payload])
      else
        :not_implemented
      end
      {name, result}
    end)
  end

  @doc "Returns all registered plugins in priority order."
  @spec list_plugins() :: [plugin_entry()]
  def list_plugins, do: GenServer.call(__MODULE__, :list)

  @impl GenServer
  def init(_opts), do: {:ok, %{plugins: []}}

  @impl GenServer
  def handle_call({:register, name, module, priority}, _from, %{plugins: plugins} = state) do
    if Enum.any?(plugins, &(&1.name == name)) do
      {:reply, {:error, :already_registered}, state}
    else
      entry = %{name: name, module: module, priority: priority}
      sorted = Enum.sort_by([entry | plugins], & &1.priority)
      if function_exported?(module, :on_register, 0), do: module.on_register()
      {:reply, :ok, %{state | plugins: sorted}}
    end
  end

  @impl GenServer
  def handle_call({:unregister, name}, _from, %{plugins: plugins} = state) do
    case Enum.find(plugins, &(&1.name == name)) do
      nil ->
        {:reply, {:error, :not_found}, state}

      %{module: module} = _entry ->
        if function_exported?(module, :on_unregister, 0), do: module.on_unregister()
        remaining = Enum.reject(plugins, &(&1.name == name))
        {:reply, :ok, %{state | plugins: remaining}}
    end
  end

  @impl GenServer
  def handle_call(:list, _from, state) do
    {:reply, state.plugins, state}
  end
end

defmodule Platform.Plugin do
  @moduledoc "Behaviour that all plugins must implement."

  @doc "Called when the plugin is registered."
  @callback on_register() :: :ok
  @optional_callbacks on_register: 0

  @doc "Called when the plugin is unregistered."
  @callback on_unregister() :: :ok
  @optional_callbacks on_unregister: 0

  @doc "A generic hook that plugins may implement."
  @callback handle_event(payload :: term()) :: term()
  @optional_callbacks handle_event: 1
end
```
