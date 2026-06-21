```elixir
defmodule Cache.HashRing do
  @moduledoc """
  A pure-functional consistent hashing ring for distributing cache keys
  evenly across a set of named nodes. Virtual nodes (replicas) are used
  to improve key distribution uniformity. Adding or removing a physical
  node redistributes only a proportional fraction of keys rather than the
  entire keyspace. The ring is immutable; all mutation operations return
  a new ring struct.
  """

  @enforce_keys [:ring, :virtual_nodes]
  defstruct [:ring, :virtual_nodes]

  @type node_name :: binary()
  @type t :: %__MODULE__{
          ring: :gb_trees.tree(),
          virtual_nodes: pos_integer()
        }

  @default_virtual_nodes 150

  # ---------------------------------------------------------------------------
  # Construction
  # ---------------------------------------------------------------------------

  @doc """
  Creates a new empty hash ring with `virtual_nodes` virtual replicas per
  physical node. More virtual nodes improves distribution at the cost of
  memory proportional to `nodes * virtual_nodes`.
  """
  @spec new(pos_integer()) :: t()
  def new(virtual_nodes \\ @default_virtual_nodes) when is_integer(virtual_nodes) and virtual_nodes > 0 do
    %__MODULE__{ring: :gb_trees.empty(), virtual_nodes: virtual_nodes}
  end

  @doc """
  Returns a new ring with `node_name` and all its virtual nodes inserted.
  Adding a node that already exists first removes the old entry.
  """
  @spec add_node(t(), node_name()) :: t()
  def add_node(%__MODULE__{} = ring, node_name) when is_binary(node_name) do
    ring = remove_node(ring, node_name)

    updated_tree =
      Enum.reduce(1..ring.virtual_nodes, ring.ring, fn replica, tree ->
        hash = compute_hash("#{node_name}:#{replica}")
        :gb_trees.insert(hash, node_name, tree)
      end)

    %{ring | ring: updated_tree}
  end

  @doc """
  Returns a new ring with `node_name` and its virtual nodes removed.
  Returns the ring unchanged if the node is not present.
  """
  @spec remove_node(t(), node_name()) :: t()
  def remove_node(%__MODULE__{} = ring, node_name) when is_binary(node_name) do
    updated_tree =
      Enum.reduce(1..ring.virtual_nodes, ring.ring, fn replica, tree ->
        hash = compute_hash("#{node_name}:#{replica}")

        if :gb_trees.is_defined(hash, tree) do
          :gb_trees.delete(hash, tree)
        else
          tree
        end
      end)

    %{ring | ring: updated_tree}
  end

  @doc """
  Returns the node responsible for `key` by walking clockwise from the
  key's hash position. Returns `{:ok, node_name}` or `{:error, :empty_ring}`.
  """
  @spec node_for(t(), binary()) :: {:ok, node_name()} | {:error, :empty_ring}
  def node_for(%__MODULE__{ring: ring}, key) when is_binary(key) do
    if :gb_trees.is_empty(ring) do
      {:error, :empty_ring}
    else
      hash = compute_hash(key)
      iter = :gb_trees.iterator_from(hash, ring)
      node = find_clockwise(iter, ring)
      {:ok, node}
    end
  end

  @doc """
  Returns up to `count` distinct physical nodes responsible for `key`,
  walking clockwise. Useful for replication where multiple nodes hold copies.
  """
  @spec nodes_for(t(), binary(), pos_integer()) :: {:ok, [node_name()]} | {:error, :empty_ring}
  def nodes_for(%__MODULE__{} = ring, key, count) when is_binary(key) and is_integer(count) and count > 0 do
    if :gb_trees.is_empty(ring.ring) do
      {:error, :empty_ring}
    else
      hash = compute_hash(key)
      nodes = collect_nodes(ring.ring, hash, count, [])
      {:ok, nodes}
    end
  end

  @doc """
  Returns the list of distinct physical nodes currently in the ring.
  """
  @spec nodes(t()) :: [node_name()]
  def nodes(%__MODULE__{ring: ring}) do
    ring
    |> :gb_trees.values()
    |> Enum.uniq()
    |> Enum.sort()
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp compute_hash(key) do
    <<hash::unsigned-32, _::binary>> = :crypto.hash(:sha256, key)
    hash
  end

  defp find_clockwise(iter, ring) do
    case :gb_trees.next(iter) do
      {_hash, node, _next_iter} -> node
      none when none == :none ->
        {_hash, node} = :gb_trees.smallest(ring)
        node
    end
  end

  defp collect_nodes(_ring, _hash, 0, acc), do: Enum.reverse(acc)

  defp collect_nodes(ring, hash, remaining, acc) do
    iter = :gb_trees.iterator_from(hash, ring)
    node = find_clockwise(iter, ring)

    if node in acc do
      if length(Enum.uniq(:gb_trees.values(ring))) <= length(acc) do
        Enum.reverse(acc)
      else
        next_hash = compute_hash("#{hash}")
        collect_nodes(ring, next_hash, remaining, acc)
      end
    else
      collect_nodes(ring, hash + 1, remaining - 1, [node | acc])
    end
  end
end
```
