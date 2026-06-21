```elixir
defmodule HashRing do
  @moduledoc """
  A consistent hash ring for distributing keys across a set of named nodes.

  Virtual nodes (replicas) are placed at multiple positions on the ring for
  each physical node so that adding or removing a node rebalances only
  `1 / num_nodes` of all keys on average. The ring is represented as a
  sorted list of `{hash, node}` pairs enabling O(log n) lookup via binary
  search.
  """

  @type node_name :: term()
  @type t :: %__MODULE__{
          nodes: [node_name()],
          ring: [{non_neg_integer(), node_name()}],
          virtual_nodes: pos_integer()
        }

  defstruct [nodes: [], ring: [], virtual_nodes: 150]

  @spec new(pos_integer()) :: t()
  def new(virtual_nodes \\ 150) when is_integer(virtual_nodes) and virtual_nodes > 0 do
    %__MODULE__{virtual_nodes: virtual_nodes}
  end

  @spec add_node(t(), node_name()) :: t()
  def add_node(%__MODULE__{} = ring, node) do
    if node in ring.nodes do
      ring
    else
      new_points = virtual_points(node, ring.virtual_nodes)
      updated_ring = Enum.sort_by(ring.ring ++ new_points, &elem(&1, 0))
      %{ring | nodes: [node | ring.nodes], ring: updated_ring}
    end
  end

  @spec remove_node(t(), node_name()) :: t()
  def remove_node(%__MODULE__{} = ring, node) do
    updated_ring = Enum.reject(ring.ring, fn {_hash, n} -> n == node end)
    %{ring | nodes: List.delete(ring.nodes, node), ring: updated_ring}
  end

  @spec get_node(t(), term()) :: {:ok, node_name()} | {:error, :empty_ring}
  def get_node(%__MODULE__{ring: []}, _key), do: {:error, :empty_ring}

  def get_node(%__MODULE__{ring: ring}, key) do
    hash = hash_key(key)
    node = find_node(ring, hash)
    {:ok, node}
  end

  @spec get_nodes(t(), term(), pos_integer()) :: [node_name()]
  def get_nodes(%__MODULE__{ring: []}, _key, _count), do: []

  def get_nodes(%__MODULE__{ring: ring, nodes: nodes} = r, key, count) do
    n = min(count, length(nodes))
    hash = hash_key(key)
    start_idx = find_start_index(ring, hash)

    ring
    |> Stream.cycle()
    |> Stream.drop(start_idx)
    |> Stream.map(&elem(&1, 1))
    |> Stream.uniq()
    |> Enum.take(n)
  end

  @spec node_count(t()) :: non_neg_integer()
  def node_count(%__MODULE__{nodes: nodes}), do: length(nodes)

  defp virtual_points(node, count) do
    Enum.map(0..(count - 1), fn i ->
      {hash_key("#{inspect(node)}-#{i}"), node}
    end)
  end

  defp find_node(ring, hash) do
    ring
    |> Enum.find(fn {h, _} -> h >= hash end)
    |> case do
      nil -> ring |> List.first() |> elem(1)
      {_h, node} -> node
    end
  end

  defp find_start_index(ring, hash) do
    idx = Enum.find_index(ring, fn {h, _} -> h >= hash end)
    idx || 0
  end

  defp hash_key(key) do
    :erlang.phash2(key, 4_294_967_296)
  end
end
```
