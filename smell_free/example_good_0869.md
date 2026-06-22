```elixir
defmodule MyApp.Infra.ClusterState do
  @moduledoc """
  Maintains a consistent view of the BEAM cluster topology and exposes
  helpers for choosing a canonical primary node for singleton work. The
  primary node is always the lexicographically smallest connected node
  so that any node in the cluster can independently arrive at the same
  decision without coordination.

  The state is updated reactively via `:net_kernel.monitor_nodes/1` so
  no polling is required.
  """

  use GenServer

  require Logger

  @doc "Starts the cluster state monitor."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Returns the list of all connected BEAM nodes including the local node."
  @spec all_nodes() :: [node()]
  def all_nodes, do: GenServer.call(__MODULE__, :all_nodes)

  @doc """
  Returns the canonical primary node for singleton scheduling.
  Any node in the cluster will return the same value.
  """
  @spec primary_node() :: node()
  def primary_node, do: GenServer.call(__MODULE__, :primary_node)

  @doc "Returns `true` when the calling node is the current primary."
  @spec primary?() :: boolean()
  def primary?, do: primary_node() == Node.self()

  @doc "Returns the number of nodes currently in the cluster."
  @spec size() :: pos_integer()
  def size, do: GenServer.call(__MODULE__, :size)

  @impl GenServer
  def init(_opts) do
    :net_kernel.monitor_nodes(true, node_type: :all)
    connected = [Node.self() | Node.list()]
    {:ok, %{nodes: MapSet.new(connected)}}
  end

  @impl GenServer
  def handle_call(:all_nodes, _from, state) do
    {:reply, MapSet.to_list(state.nodes), state}
  end

  @impl GenServer
  def handle_call(:primary_node, _from, state) do
    primary = state.nodes |> MapSet.to_list() |> Enum.min()
    {:reply, primary, state}
  end

  @impl GenServer
  def handle_call(:size, _from, state) do
    {:reply, MapSet.size(state.nodes), state}
  end

  @impl GenServer
  def handle_info({:nodeup, node, _info}, state) do
    Logger.info("cluster_node_joined", node: node, cluster_size: MapSet.size(state.nodes) + 1)
    {:noreply, %{state | nodes: MapSet.put(state.nodes, node)}}
  end

  @impl GenServer
  def handle_info({:nodedown, node, _info}, state) do
    Logger.warning("cluster_node_left", node: node, cluster_size: MapSet.size(state.nodes) - 1)
    {:noreply, %{state | nodes: MapSet.delete(state.nodes, node)}}
  end

  @impl GenServer
  def handle_info(_msg, state), do: {:noreply, state}
end
```
