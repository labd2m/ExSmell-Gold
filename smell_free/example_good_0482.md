```elixir
defmodule Plugin.Spec do
  @moduledoc false

  @type t :: %__MODULE__{
          name: atom(),
          module: module(),
          capabilities: [atom()],
          priority: integer()
        }

  defstruct [:name, :module, :capabilities, priority: 0]

  @spec new(atom(), module(), [atom()], integer()) :: t()
  def new(name, module, capabilities, priority \\ 0)
      when is_atom(name) and is_atom(module) and is_list(capabilities) do
    %__MODULE__{name: name, module: module, capabilities: capabilities, priority: priority}
  end
end

defmodule Plugin.Registry do
  @moduledoc """
  Manages a collection of named plugin modules dispatched by capability.

  Plugins declare which capabilities they implement. When a capability is
  invoked via `dispatch/3`, all registered plugins advertising that
  capability are called in priority order (highest first). Results are
  collected and returned; a plugin error is isolated and recorded without
  preventing other plugins from running.
  """

  use GenServer

  alias Plugin.Spec

  @type capability :: atom()
  @type dispatch_result :: [{atom(), {:ok, term()} | {:error, term()}}]

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec register(Spec.t()) :: :ok | {:error, :duplicate_plugin}
  def register(%Spec{} = spec) do
    GenServer.call(__MODULE__, {:register, spec})
  end

  @spec deregister(atom()) :: :ok
  def deregister(name) when is_atom(name) do
    GenServer.cast(__MODULE__, {:deregister, name})
  end

  @spec dispatch(capability(), atom(), [term()]) :: dispatch_result()
  def dispatch(capability, function, args \\ [])
      when is_atom(capability) and is_atom(function) and is_list(args) do
    GenServer.call(__MODULE__, {:dispatch, capability, function, args})
  end

  @spec plugins_for(capability()) :: [Spec.t()]
  def plugins_for(capability) when is_atom(capability) do
    GenServer.call(__MODULE__, {:for_capability, capability})
  end

  @impl GenServer
  def init(_opts), do: {:ok, %{plugins: %{}}}

  @impl GenServer
  def handle_call({:register, %Spec{name: name} = spec}, _from, state) do
    if Map.has_key?(state.plugins, name) do
      {:reply, {:error, :duplicate_plugin}, state}
    else
      {:reply, :ok, %{state | plugins: Map.put(state.plugins, name, spec)}}
    end
  end

  def handle_call({:dispatch, capability, function, args}, _from, state) do
    matching =
      state.plugins
      |> Map.values()
      |> Enum.filter(fn spec -> capability in spec.capabilities end)
      |> Enum.sort_by(& &1.priority, :desc)

    results =
      Enum.map(matching, fn spec ->
        result =
          try do
            {:ok, apply(spec.module, function, args)}
          rescue
            error -> {:error, {:exception, error}}
          end

        {spec.name, result}
      end)

    {:reply, results, state}
  end

  def handle_call({:for_capability, capability}, _from, state) do
    plugins =
      state.plugins
      |> Map.values()
      |> Enum.filter(&(capability in &1.capabilities))
      |> Enum.sort_by(& &1.priority, :desc)

    {:reply, plugins, state}
  end

  @impl GenServer
  def handle_cast({:deregister, name}, state) do
    {:noreply, %{state | plugins: Map.delete(state.plugins, name)}}
  end
end
```
