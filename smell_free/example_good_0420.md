# File: `example_good_420.md`

```elixir
defmodule Cluster.ConsistentHashRing do
  @moduledoc """
  GenServer implementing a consistent hash ring for distributing keys
  across a dynamic set of nodes.

  Each physical node is mapped to multiple virtual nodes (replicas) on
  the ring to achieve uniform distribution. When a node is added or
  removed, only the keys in the affected segment are remapped rather
  than all keys.
  """

  use GenServer

  @default_replicas 150

  @type node_name :: String.t()
  @type ring_key :: term()

  @type opts :: [replicas: pos_integer()]

  @doc false
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Adds a node to the ring with the configured number of virtual replicas.

  Returns `:ok` or `{:error, :already_member}`.
  """
  @spec add_node(node_name()) :: :ok | {:error, :already_member}
  def add_node(node_name) when is_binary(node_name) do
    GenServer.call(__MODULE__, {:add_node, node_name})
  end

  @doc """
  Removes a node and all its virtual replicas from the ring.

  Returns `:ok` or `{:error, :not_member}`.
  """
  @spec remove_node(node_name()) :: :ok | {:error, :not_member}
  def remove_node(node_name) when is_binary(node_name) do
    GenServer.call(__MODULE__, {:remove_node, node_name})
  end

  @doc """
  Returns the node responsible for `key` according to the ring.

  Returns `{:ok, node_name}` or `{:error, :empty_ring}`.
  """
  @spec node_for(ring_key()) :: {:ok, node_name()} | {:error, :empty_ring}
  def node_for(key) do
    GenServer.call(__MODULE__, {:node_for, key})
  end

  @doc """
  Returns `n` distinct nodes responsible for successive positions after
  `key` on the ring. Useful for replication placement.

  Returns fewer than `n` nodes when the ring has fewer members.
  """
  @spec nodes_for(ring_key(), pos_integer()) :: [node_name()]
  def nodes_for(key, n) when is_integer(n) and n > 0 do
    GenServer.call(__MODULE__, {:nodes_for, key, n})
  end

  @doc """
  Returns all node names currently in the ring.
  """
  @spec members() :: [node_name()]
  def members do
    GenServer.call(__MODULE__, :members)
  end

  @impl GenServer
  def init(opts) do
    replicas = Keyword.get(opts, :replicas, @default_replicas)
    {:ok, %{ring: [], nodes: MapSet.new(), replicas: replicas}}
  end

  @impl GenServer
  def handle_call({:add_node, name}, _from, state) do
    if MapSet.member?(state.nodes, name) do
      {:reply, {:error, :already_member}, state}
    else
      new_ring = add_virtual_nodes(state.ring, name, state.replicas)
      new_nodes = MapSet.put(state.nodes, name)
      {:reply, :ok, %{state | ring: new_ring, nodes: new_nodes}}
    end
  end

  @impl GenServer
  def handle_call({:remove_node, name}, _from, state) do
    if MapSet.member?(state.nodes, name) do
      new_ring = Enum.reject(state.ring, fn {_hash, n} -> n == name end)
      new_nodes = MapSet.delete(state.nodes, name)
      {:reply, :ok, %{state | ring: new_ring, nodes: new_nodes}}
    else
      {:reply, {:error, :not_member}, state}
    end
  end

  @impl GenServer
  def handle_call({:node_for, key}, _from, %{ring: []} = state) do
    {:reply, {:error, :empty_ring}, state}
  end

  @impl GenServer
  def handle_call({:node_for, key}, _from, state) do
    node = lookup_node(state.ring, hash(key))
    {:reply, {:ok, node}, state}
  end

  @impl GenServer
  def handle_call({:nodes_for, key, n}, _from, state) do
    nodes = collect_distinct_nodes(state.ring, hash(key), n)
    {:reply, nodes, state}
  end

  @impl GenServer
  def handle_call(:members, _from, state) do
    {:reply, MapSet.to_list(state.nodes), state}
  end

  defp add_virtual_nodes(ring, name, replicas) do
    new_entries =
      Enum.map(1..replicas, fn i ->
        {hash("#{name}:#{i}"), name}
      end)

    (ring ++ new_entries) |> Enum.sort_by(&elem(&1, 0))
  end

  defp lookup_node(ring, key_hash) do
    ring
    |> Enum.find(fn {h, _name} -> h >= key_hash end)
    |> case do
      nil -> elem(List.first(ring), 1)
      {_h, name} -> name
    end
  end

  defp collect_distinct_nodes(ring, key_hash, n) do
    start_index =
      Enum.find_index(ring, fn {h, _} -> h >= key_hash end) || 0

    Stream.cycle(ring)
    |> Stream.drop(start_index)
    |> Stream.map(&elem(&1, 1))
    |> Stream.uniq()
    |> Enum.take(min(n, length(ring)))
  end

  defp hash(value) do
    :erlang.phash2(value, 4_294_967_296)
  end
end
```
