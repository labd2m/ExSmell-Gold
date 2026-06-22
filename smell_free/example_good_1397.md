**File:** `example_good_1397.md`

```elixir
defmodule PluginSystem.Capability do
  @moduledoc "Represents a named capability that a plugin can declare or require."

  @enforce_keys [:name, :version]
  defstruct [:name, :version, :description]

  @type t :: %__MODULE__{
          name: atom(),
          version: String.t(),
          description: String.t() | nil
        }

  @spec new(atom(), String.t(), keyword()) :: t()
  def new(name, version, opts \\ []) when is_atom(name) and is_binary(version) do
    %__MODULE__{
      name: name,
      version: version,
      description: Keyword.get(opts, :description)
    }
  end
end

defmodule PluginSystem.Manifest do
  @moduledoc "Describes a plugin's identity, dependencies, and declared capabilities."

  @enforce_keys [:id, :name, :version, :module]
  defstruct [:id, :name, :version, :module, :description,
             provides: [], requires: [], config_schema: []]

  @type t :: %__MODULE__{
          id: atom(),
          name: String.t(),
          version: String.t(),
          module: module(),
          description: String.t() | nil,
          provides: [PluginSystem.Capability.t()],
          requires: [atom()],
          config_schema: keyword()
        }
end

defmodule PluginSystem.Plugin do
  @moduledoc "Behaviour contract for all plugins in the system."

  @doc "Returns this plugin's manifest."
  @callback manifest() :: PluginSystem.Manifest.t()

  @doc "Initialises the plugin with validated runtime config."
  @callback init(map()) :: {:ok, term()} | {:error, term()}

  @doc "Tears down any resources held by the plugin."
  @callback terminate(term()) :: :ok
end

defmodule PluginSystem.Registry do
  @moduledoc """
  Manages plugin registration, capability resolution, and dependency
  validation. Plugins are registered with their manifests and config.
  """

  use Agent

  alias PluginSystem.{Capability, Manifest, Plugin}

  @type plugin_entry :: %{manifest: Manifest.t(), state: term()}

  @spec start_link(keyword()) :: Agent.on_start()
  def start_link(opts \\ []) do
    Agent.start_link(fn -> %{} end, name: Keyword.get(opts, :name, __MODULE__))
  end

  @spec register(module(), map()) ::
          {:ok, Manifest.t()} | {:error, :missing_capabilities | :already_registered | term()}
  def register(plugin_module, config \\ %{}) when is_atom(plugin_module) do
    manifest = plugin_module.manifest()

    with :ok <- check_not_registered(manifest.id),
         :ok <- check_required_capabilities(manifest.requires),
         {:ok, state} <- plugin_module.init(config) do
      entry = %{manifest: manifest, state: state}
      Agent.update(__MODULE__, &Map.put(&1, manifest.id, entry))
      {:ok, manifest}
    end
  end

  @spec unregister(atom()) :: :ok | {:error, :not_found}
  def unregister(plugin_id) when is_atom(plugin_id) do
    Agent.get_and_update(__MODULE__, fn plugins ->
      case Map.pop(plugins, plugin_id) do
        {nil, _} ->
          {{:error, :not_found}, plugins}

        {%{manifest: %{module: mod}, state: state}, updated} ->
          mod.terminate(state)
          {:ok, updated}
      end
    end)
  end

  @spec provides?(atom()) :: boolean()
  def provides?(capability_name) when is_atom(capability_name) do
    Agent.get(__MODULE__, fn plugins ->
      Enum.any?(plugins, fn {_, %{manifest: m}} ->
        Enum.any?(m.provides, fn %Capability{name: n} -> n == capability_name end)
      end)
    end)
  end

  @spec list_plugins() :: [Manifest.t()]
  def list_plugins do
    Agent.get(__MODULE__, fn plugins ->
      Enum.map(plugins, fn {_, %{manifest: m}} -> m end)
    end)
  end

  @spec get_plugin(atom()) :: {:ok, plugin_entry()} | {:error, :not_found}
  def get_plugin(plugin_id) when is_atom(plugin_id) do
    case Agent.get(__MODULE__, &Map.get(&1, plugin_id)) do
      nil -> {:error, :not_found}
      entry -> {:ok, entry}
    end
  end

  defp check_not_registered(id) do
    case Agent.get(__MODULE__, &Map.has_key?(&1, id)) do
      true -> {:error, :already_registered}
      false -> :ok
    end
  end

  defp check_required_capabilities([]), do: :ok

  defp check_required_capabilities(required) do
    missing = Enum.reject(required, &provides?/1)

    if missing == [] do
      :ok
    else
      {:error, {:missing_capabilities, missing}}
    end
  end
end
```
