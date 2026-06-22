```elixir
defmodule Plugins.Registry do
  @moduledoc """
  A supervised GenServer that manages a registry of named plugin modules.
  Plugins declare a behaviour with optional lifecycle hooks (`init`, `teardown`).
  The registry loads, validates, and unloads plugins at runtime without restarts.
  """

  use GenServer

  @type plugin_name :: atom()
  @type plugin_config :: keyword()

  @type plugin_entry :: %{
          name: plugin_name(),
          module: module(),
          config: plugin_config(),
          state: term(),
          loaded_at: DateTime.t()
        }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec load(plugin_name(), module(), plugin_config()) ::
          :ok | {:error, :already_loaded | :invalid_plugin | term()}
  def load(name, module, config \\ []) when is_atom(name) and is_atom(module) do
    GenServer.call(__MODULE__, {:load, name, module, config})
  end

  @spec unload(plugin_name()) :: :ok | {:error, :not_found}
  def unload(name) when is_atom(name) do
    GenServer.call(__MODULE__, {:unload, name})
  end

  @spec call_hook(plugin_name(), atom(), [term()]) ::
          {:ok, term()} | {:error, :not_found | :hook_not_implemented}
  def call_hook(name, hook, args \\ []) when is_atom(name) and is_atom(hook) do
    GenServer.call(__MODULE__, {:hook, name, hook, args})
  end

  @spec broadcast_hook(atom(), [term()]) :: %{plugin_name() => {:ok, term()} | {:error, term()}}
  def broadcast_hook(hook, args \\ []) when is_atom(hook) do
    GenServer.call(__MODULE__, {:broadcast, hook, args})
  end

  @spec list_plugins() :: [%{name: plugin_name(), module: module(), loaded_at: DateTime.t()}]
  def list_plugins do
    GenServer.call(__MODULE__, :list)
  end

  @impl GenServer
  def init(_opts) do
    {:ok, %{plugins: %{}}}
  end

  @impl GenServer
  def handle_call({:load, name, module, config}, _from, state) do
    if Map.has_key?(state.plugins, name) do
      {:reply, {:error, :already_loaded}, state}
    else
      case validate_and_init(module, config) do
        {:ok, plugin_state} ->
          entry = %{name: name, module: module, config: config, state: plugin_state, loaded_at: DateTime.utc_now()}
          {:reply, :ok, put_in(state, [:plugins, name], entry)}

        {:error, reason} ->
          {:reply, {:error, reason}, state}
      end
    end
  end

  def handle_call({:unload, name}, _from, state) do
    case Map.fetch(state.plugins, name) do
      :error ->
        {:reply, {:error, :not_found}, state}

      {:ok, entry} ->
        run_teardown(entry)
        {:reply, :ok, update_in(state, [:plugins], &Map.delete(&1, name))}
    end
  end

  def handle_call({:hook, name, hook, args}, _from, state) do
    case Map.fetch(state.plugins, name) do
      :error ->
        {:reply, {:error, :not_found}, state}

      {:ok, entry} ->
        result = invoke_hook(entry, hook, args)
        {:reply, result, state}
    end
  end

  def handle_call({:broadcast, hook, args}, _from, state) do
    results = Map.new(state.plugins, fn {name, entry} ->
      {name, invoke_hook(entry, hook, args)}
    end)
    {:reply, results, state}
  end

  def handle_call(:list, _from, state) do
    list = Enum.map(state.plugins, fn {name, e} ->
      %{name: name, module: e.module, loaded_at: e.loaded_at}
    end)
    {:reply, list, state}
  end

  @spec validate_and_init(module(), plugin_config()) :: {:ok, term()} | {:error, term()}
  defp validate_and_init(module, config) do
    if function_exported?(module, :init, 1) do
      case module.init(config) do
        {:ok, state} -> {:ok, state}
        {:error, reason} -> {:error, reason}
        _ -> {:error, :invalid_init_return}
      end
    else
      {:ok, nil}
    end
  rescue
    e -> {:error, {:init_exception, Exception.message(e)}}
  end

  @spec run_teardown(plugin_entry()) :: :ok
  defp run_teardown(entry) do
    if function_exported?(entry.module, :teardown, 1) do
      entry.module.teardown(entry.state)
    end

    :ok
  rescue
    _ -> :ok
  end

  @spec invoke_hook(plugin_entry(), atom(), [term()]) ::
          {:ok, term()} | {:error, :hook_not_implemented | term()}
  defp invoke_hook(entry, hook, args) do
    arity = length(args) + 1

    if function_exported?(entry.module, hook, arity) do
      result = apply(entry.module, hook, args ++ [entry.state])
      {:ok, result}
    else
      {:error, :hook_not_implemented}
    end
  rescue
    e -> {:error, {:hook_exception, Exception.message(e)}}
  end
end
```
