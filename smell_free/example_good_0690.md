```elixir
defmodule Platform.PluginLoader do
  @moduledoc """
  Loads and validates third-party plugin modules at application startup.
  Each plugin must implement the `Platform.Plugin` behaviour and declare
  a version, name, and list of capabilities. The loader validates each
  candidate module before registering it, preventing incompatible or
  incomplete plugins from affecting the running system.
  """

  require Logger

  @type plugin_module :: module()
  @type capability :: atom()
  @type plugin_info :: %{
          module: plugin_module(),
          name: String.t(),
          version: String.t(),
          capabilities: [capability()]
        }

  @type load_result :: %{
          loaded: [plugin_info()],
          rejected: [%{module: plugin_module(), reason: atom()}]
        }

  @required_callbacks [:name, :version, :capabilities, :start]
  @supported_capabilities ~w(storage notification analytics auth)a

  @doc """
  Loads all plugin modules listed in `modules`. Validates each against the
  `Platform.Plugin` behaviour and capability allowlist. Returns a summary
  of loaded and rejected plugins.
  """
  @spec load([plugin_module()]) :: load_result()
  def load(modules) when is_list(modules) do
    {loaded, rejected} =
      Enum.reduce(modules, {[], []}, fn mod, {loaded_acc, rejected_acc} ->
        case validate_and_load(mod) do
          {:ok, info} ->
            Logger.info("[PluginLoader] Loaded plugin: #{info.name} v#{info.version}")
            {[info | loaded_acc], rejected_acc}

          {:error, reason} ->
            Logger.warning("[PluginLoader] Rejected #{inspect(mod)}: #{reason}")
            {loaded_acc, [%{module: mod, reason: reason} | rejected_acc]}
        end
      end)

    %{loaded: Enum.reverse(loaded), rejected: Enum.reverse(rejected)}
  end

  @doc "Returns all currently loaded plugin modules from application config."
  @spec configured_plugins() :: [plugin_module()]
  def configured_plugins do
    Application.get_env(:my_app, :plugins, [])
  end

  defp validate_and_load(mod) do
    with :ok <- check_module_exists(mod),
         :ok <- check_behaviour(mod),
         :ok <- check_capabilities(mod) do
      info = %{
        module: mod,
        name: mod.name(),
        version: mod.version(),
        capabilities: mod.capabilities()
      }

      case mod.start() do
        :ok -> {:ok, info}
        {:error, reason} -> {:error, {:start_failed, reason}}
      end
    end
  rescue
    e -> {:error, {:exception, Exception.message(e)}}
  end

  defp check_module_exists(mod) do
    if Code.ensure_loaded?(mod), do: :ok, else: {:error, :module_not_found}
  end

  defp check_behaviour(mod) do
    missing = Enum.reject(@required_callbacks, &function_exported?(mod, &1, 0))

    if Enum.empty?(missing) do
      :ok
    else
      {:error, {:missing_callbacks, missing}}
    end
  end

  defp check_capabilities(mod) do
    declared = mod.capabilities()
    unsupported = Enum.reject(declared, &(&1 in @supported_capabilities))

    if Enum.empty?(unsupported) do
      :ok
    else
      {:error, {:unsupported_capabilities, unsupported}}
    end
  end
end

defmodule Platform.Plugin do
  @moduledoc "Behaviour contract for third-party platform plugins."

  @doc "Returns the human-readable plugin name."
  @callback name() :: String.t()

  @doc "Returns the plugin version string."
  @callback version() :: String.t()

  @doc "Returns the list of capabilities this plugin registers for."
  @callback capabilities() :: [atom()]

  @doc "Initialises the plugin. Called once during loading."
  @callback start() :: :ok | {:error, term()}
end
```
