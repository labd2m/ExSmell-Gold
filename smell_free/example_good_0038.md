```elixir
defmodule Cluster.NodeMonitor do
  @moduledoc """
  A GenServer that tracks the live BEAM cluster topology.

  Subscribes to Erlang node-up/node-down kernel events and maintains a
  registry of connected nodes with metadata. Topology changes are published
  via `Phoenix.PubSub` for downstream consumers to react to.
  """

  use GenServer

  require Logger

  @type node_info :: %{
          name: node(),
          connected_at: DateTime.t(),
          capabilities: [atom()]
        }

  @type state :: %{
          nodes: %{optional(node()) => node_info()},
          pubsub: atom(),
          topic: String.t()
        }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Returns metadata for all currently connected cluster nodes."
  @spec connected_nodes() :: [node_info()]
  def connected_nodes, do: GenServer.call(__MODULE__, :connected_nodes)

  @doc "Returns `true` if the given node is currently connected."
  @spec connected?(node()) :: boolean()
  def connected?(node_name) when is_atom(node_name) do
    GenServer.call(__MODULE__, {:connected?, node_name})
  end

  @doc "Returns the count of currently connected cluster nodes."
  @spec node_count() :: non_neg_integer()
  def node_count, do: GenServer.call(__MODULE__, :node_count)

  @impl GenServer
  def init(opts) do
    :net_kernel.monitor_nodes(true, node_type: :all)

    state = %{
      nodes: discover_nodes(),
      pubsub: Keyword.get(opts, :pubsub, App.PubSub),
      topic: Keyword.get(opts, :topic, "cluster:topology")
    }

    {:ok, state}
  end

  @impl GenServer
  def handle_call(:connected_nodes, _from, state) do
    {:reply, Map.values(state.nodes), state}
  end

  @impl GenServer
  def handle_call({:connected?, node_name}, _from, state) do
    {:reply, Map.has_key?(state.nodes, node_name), state}
  end

  @impl GenServer
  def handle_call(:node_count, _from, state) do
    {:reply, map_size(state.nodes), state}
  end

  @impl GenServer
  def handle_info({:nodeup, name, _info}, state) do
    Logger.info("[NodeMonitor] Node joined cluster", node: name)
    info = build_node_info(name)
    new_state = put_in(state, [:nodes, name], info)
    publish(state.pubsub, state.topic, {:node_up, info})
    {:noreply, new_state}
  end

  @impl GenServer
  def handle_info({:nodedown, name, _info}, state) do
    Logger.warning("[NodeMonitor] Node left cluster", node: name)
    new_state = %{state | nodes: Map.delete(state.nodes, name)}
    publish(state.pubsub, state.topic, {:node_down, name})
    {:noreply, new_state}
  end

  defp discover_nodes do
    Node.list(:connected)
    |> Enum.map(&{&1, build_node_info(&1)})
    |> Map.new()
  end

  defp build_node_info(node_name) do
    %{
      name: node_name,
      connected_at: DateTime.utc_now(),
      capabilities: fetch_capabilities(node_name)
    }
  end

  defp fetch_capabilities(node_name) do
    case :rpc.call(node_name, Application, :get_env, [:app, :capabilities, []], 5_000) do
      {:badrpc, _} -> []
      caps when is_list(caps) -> caps
      _ -> []
    end
  end

  defp publish(pubsub, topic, message) do
    Phoenix.PubSub.broadcast(pubsub, topic, message)
  end
end
```
