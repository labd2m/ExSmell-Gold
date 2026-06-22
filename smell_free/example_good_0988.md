```elixir
defmodule Messaging.ClusterPubSub do
  @moduledoc """
  A cluster-aware publish/subscribe system that partitions topics across nodes
  using a consistent hash ring. Unlike Phoenix.PubSub which broadcasts to all
  nodes, this module routes each topic to its owner node, reducing cross-node
  traffic for high-volume topics with many subscribers on a single node.
  Subscribers always receive events regardless of which node they connect to;
  the routing is transparent.
  """

  use GenServer

  alias Cache.HashRing

  require Logger

  @type topic :: binary()
  @type handler :: pid()

  @table :cluster_pubsub_subs
  @ring_name :cluster_pubsub_ring

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Subscribes the calling process to `topic`. Delivers messages as
  `{:pubsub_message, topic, payload}`.
  """
  @spec subscribe(topic()) :: :ok
  def subscribe(topic) when is_binary(topic) do
    GenServer.call(__MODULE__, {:subscribe, topic, self()})
  end

  @doc """
  Unsubscribes the calling process from `topic`.
  """
  @spec unsubscribe(topic()) :: :ok
  def unsubscribe(topic) when is_binary(topic) do
    GenServer.cast(__MODULE__, {:unsubscribe, topic, self()})
  end

  @doc """
  Publishes `payload` to all subscribers of `topic` across the cluster.
  Routes to the topic-owner node using the hash ring; the owner then
  broadcasts to local subscribers and forwards to other nodes.
  """
  @spec publish(topic(), term()) :: :ok
  def publish(topic, payload) when is_binary(topic) do
    owner_node = route_to_node(topic)

    if owner_node == Node.self() do
      broadcast_local(topic, payload)
      forward_to_peers(topic, payload)
    else
      :rpc.cast(owner_node, __MODULE__, :publish, [topic, payload])
    end

    :ok
  end

  @doc """
  Returns the list of topics the calling process is subscribed to.
  """
  @spec subscriptions() :: [topic()]
  def subscriptions do
    GenServer.call(__MODULE__, {:subscriptions, self()})
  end

  # ---------------------------------------------------------------------------
  # GenServer callbacks
  # ---------------------------------------------------------------------------

  @impl GenServer
  def init(_opts) do
    :ets.new(@table, [:named_table, :bag, :public])
    ring = build_ring()
    :net_kernel.monitor_nodes(true)
    {:ok, %{ring: ring}}
  end

  @impl GenServer
  def handle_call({:subscribe, topic, pid}, _from, state) do
    Process.monitor(pid)
    :ets.insert(@table, {topic, pid})
    {:reply, :ok, state}
  end

  def handle_call({:subscriptions, pid}, _from, state) do
    topics =
      :ets.tab2list(@table)
      |> Enum.filter(fn {_topic, sub_pid} -> sub_pid == pid end)
      |> Enum.map(&elem(&1, 0))

    {:reply, topics, state}
  end

  @impl GenServer
  def handle_cast({:unsubscribe, topic, pid}, state) do
    :ets.delete_object(@table, {topic, pid})
    {:noreply, state}
  end

  @impl GenServer
  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    :ets.match_delete(@table, {:_, pid})
    {:noreply, state}
  end

  def handle_info({:nodeup, node}, state) do
    Logger.info("ClusterPubSub: node joined", node: node)
    new_ring = HashRing.add_node(state.ring, to_string(node))
    {:noreply, %{state | ring: new_ring}}
  end

  def handle_info({:nodedown, node}, state) do
    Logger.info("ClusterPubSub: node left", node: node)
    new_ring = HashRing.remove_node(state.ring, to_string(node))
    {:noreply, %{state | ring: new_ring}}
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp broadcast_local(topic, payload) do
    message = {:pubsub_message, topic, payload}

    :ets.lookup(@table, topic)
    |> Enum.each(fn {^topic, pid} ->
      send(pid, message)
    end)
  end

  defp forward_to_peers(topic, payload) do
    Node.list()
    |> Enum.each(fn node ->
      :rpc.cast(node, __MODULE__, :receive_forwarded, [topic, payload])
    end)
  end

  def receive_forwarded(topic, payload) do
    broadcast_local(topic, payload)
  end

  defp route_to_node(topic) do
    ring = GenServer.call(__MODULE__, :get_ring)

    case HashRing.node_for(ring, topic) do
      {:ok, node_str} -> String.to_existing_atom(node_str)
      {:error, :empty_ring} -> Node.self()
    end
  rescue
    _ -> Node.self()
  end

  defp build_ring do
    nodes = [Node.self() | Node.list()] |> Enum.map(&to_string/1)
    Enum.reduce(nodes, HashRing.new(150), &HashRing.add_node(&2, &1))
  end
end
```
