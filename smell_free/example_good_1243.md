```elixir
defmodule Platform.Plugins.Registry do
  @moduledoc """
  Manages registration and lookup of runtime plugins identified by name and version.
  Plugins declare capabilities; the registry resolves the best-matching version
  for a requested capability constraint.
  """

  use GenServer

  @type version :: {non_neg_integer(), non_neg_integer(), non_neg_integer()}
  @type plugin :: %{
          name: String.t(),
          version: version(),
          capabilities: [atom()],
          module: module()
        }
  @type state :: %{plugins: [plugin()]}

  @doc """
  Starts the Registry linked to the calling process.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Registers a plugin. Returns `{:error, :already_registered}` if an identical
  name and version combination already exists.
  """
  @spec register(plugin()) :: :ok | {:error, :already_registered | String.t()}
  def register(plugin) when is_map(plugin) do
    case validate_plugin(plugin) do
      :ok -> GenServer.call(__MODULE__, {:register, plugin})
      {:error, _} = err -> err
    end
  end

  @doc """
  Looks up all registered plugins providing `capability`.
  Returns them sorted by version descending.
  """
  @spec lookup_by_capability(atom()) :: [plugin()]
  def lookup_by_capability(capability) when is_atom(capability) do
    GenServer.call(__MODULE__, {:lookup_capability, capability})
  end

  @doc """
  Returns the highest-versioned plugin for `name`, if registered.
  """
  @spec fetch_latest(String.t()) :: {:ok, plugin()} | {:error, :not_found}
  def fetch_latest(name) when is_binary(name) do
    GenServer.call(__MODULE__, {:fetch_latest, name})
  end

  @doc """
  Removes all versions of a plugin by name.
  """
  @spec deregister(String.t()) :: :ok
  def deregister(name) when is_binary(name) do
    GenServer.cast(__MODULE__, {:deregister, name})
  end

  @impl GenServer
  def init(_opts), do: {:ok, %{plugins: []}}

  @impl GenServer
  def handle_call({:register, plugin}, _from, state) do
    already_exists =
      Enum.any?(state.plugins, fn p ->
        p.name == plugin.name and p.version == plugin.version
      end)

    if already_exists do
      {:reply, {:error, :already_registered}, state}
    else
      {:reply, :ok, %{state | plugins: [plugin | state.plugins]}}
    end
  end

  @impl GenServer
  def handle_call({:lookup_capability, capability}, _from, state) do
    matches =
      state.plugins
      |> Enum.filter(fn p -> capability in p.capabilities end)
      |> Enum.sort_by(fn p -> p.version end, :desc)

    {:reply, matches, state}
  end

  @impl GenServer
  def handle_call({:fetch_latest, name}, _from, state) do
    result =
      state.plugins
      |> Enum.filter(fn p -> p.name == name end)
      |> Enum.sort_by(fn p -> p.version end, :desc)
      |> List.first()

    reply = if is_nil(result), do: {:error, :not_found}, else: {:ok, result}
    {:reply, reply, state}
  end

  @impl GenServer
  def handle_cast({:deregister, name}, state) do
    updated = Enum.reject(state.plugins, fn p -> p.name == name end)
    {:noreply, %{state | plugins: updated}}
  end

  defp validate_plugin(%{name: n, version: {ma, mi, p}, capabilities: caps, module: mod})
       when is_binary(n) and n != "" and is_integer(ma) and is_integer(mi) and
              is_integer(p) and is_list(caps) and is_atom(mod),
       do: :ok

  defp validate_plugin(_), do: {:error, "plugin must have name, version tuple, capabilities, and module"}
end
```
