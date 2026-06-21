```elixir
defmodule MyApp.Cluster.NodeMonitor do
  @moduledoc """
  Monitors connected BEAM cluster nodes and triggers application-level
  callbacks when the cluster topology changes. Callbacks are registered
  as MFA tuples and invoked synchronously in the monitor process so that
  ordering is preserved within a single topology change event.

  Start this module under the application supervisor:

      children = [MyApp.Cluster.NodeMonitor]
  """

  use GenServer

  require Logger

  @type mfa_callback :: {module(), atom(), list()}
  @type event :: :node_up | :node_down
  @type state :: %{
          known_nodes: MapSet.t(),
          callbacks: [{event(), mfa_callback()}]
        }

  @doc "Starts the node monitor."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Registers `callback` to be invoked when `event` fires.
  `callback` is an `{module, function, extra_args}` tuple; the affected
  node name is prepended to `extra_args` before invocation.
  """
  @spec register_callback(event(), mfa_callback()) :: :ok
  def register_callback(event, {_m, _f, _a} = callback)
      when event in [:node_up, :node_down] do
    GenServer.call(__MODULE__, {:register, event, callback})
  end

  @doc "Returns the set of BEAM nodes currently known to be connected."
  @spec connected_nodes() :: [node()]
  def connected_nodes do
    GenServer.call(__MODULE__, :connected_nodes)
  end

  @impl GenServer
  def init(_opts) do
    :net_kernel.monitor_nodes(true, node_type: :all)

    state = %{
      known_nodes: MapSet.new(Node.list()),
      callbacks: []
    }

    {:ok, state}
  end

  @impl GenServer
  def handle_call({:register, event, callback}, _from, state) do
    {:reply, :ok, %{state | callbacks: [{event, callback} | state.callbacks]}}
  end

  @impl GenServer
  def handle_call(:connected_nodes, _from, state) do
    {:reply, MapSet.to_list(state.known_nodes), state}
  end

  @impl GenServer
  def handle_info({:nodeup, node, _info}, state) do
    Logger.info("cluster_node_up", node: node)
    invoke_callbacks(:node_up, node, state.callbacks)
    {:noreply, %{state | known_nodes: MapSet.put(state.known_nodes, node)}}
  end

  @impl GenServer
  def handle_info({:nodedown, node, _info}, state) do
    Logger.warning("cluster_node_down", node: node)
    invoke_callbacks(:node_down, node, state.callbacks)
    {:noreply, %{state | known_nodes: MapSet.delete(state.known_nodes, node)}}
  end

  @impl GenServer
  def handle_info(_msg, state), do: {:noreply, state}

  @spec invoke_callbacks(event(), node(), [{event(), mfa_callback()}]) :: :ok
  defp invoke_callbacks(event, node_name, callbacks) do
    callbacks
    |> Enum.filter(fn {ev, _} -> ev == event end)
    |> Enum.each(fn {_, {mod, fun, args}} ->
      apply(mod, fun, [node_name | args])
    rescue
      err ->
        Logger.error("node_monitor_callback_failed",
          event: event,
          node: node_name,
          error: inspect(err)
        )
    end)
  end
end
```
