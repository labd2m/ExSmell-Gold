```elixir
defmodule Cache.ConsistentHashRing do
  @moduledoc """
  Consistent hash ring for distributing cache keys across a set of named nodes.

  Virtual nodes (replicas) are used to improve key distribution uniformity.
  The ring supports adding and removing nodes without full redistribution.
  All operations are pure; the ring is an immutable data structure.
  """

  @virtual_nodes 150

  @enforce_keys [:ring, :nodes]
  defstruct [:ring, :nodes]

  @type node_id :: String.t()
  @type t :: %__MODULE__{
          ring: [{non_neg_integer(), node_id()}],
          nodes: MapSet.t()
        }

  @doc """
  Builds a new ring from a list of node identifiers.
  """
  @spec new([node_id()]) :: t()
  def new(nodes) when is_list(nodes) do
    ring =
      nodes
      |> Enum.flat_map(&virtual_points/1)
      |> Enum.sort_by(fn {hash, _} -> hash end)

    %__MODULE__{ring: ring, nodes: MapSet.new(nodes)}
  end

  @doc """
  Returns the node responsible for the given key.
  """
  @spec node_for(t(), String.t()) :: {:ok, node_id()} | {:error, :empty_ring}
  def node_for(%__MODULE__{ring: []}, _key), do: {:error, :empty_ring}

  def node_for(%__MODULE__{ring: ring}, key) when is_binary(key) do
    hash = hash_key(key)

    node =
      ring
      |> Enum.find(fn {point, _node} -> point >= hash end)
      |> case do
        nil -> elem(hd(ring), 1)
        {_, node_id} -> node_id
      end

    {:ok, node}
  end

  @doc """
  Adds a node to the ring.
  """
  @spec add_node(t(), node_id()) :: t()
  def add_node(%__MODULE__{ring: ring, nodes: nodes}, node_id) when is_binary(node_id) do
    new_points = virtual_points(node_id)

    updated_ring =
      (ring ++ new_points)
      |> Enum.sort_by(fn {hash, _} -> hash end)

    %__MODULE__{ring: updated_ring, nodes: MapSet.put(nodes, node_id)}
  end

  @doc """
  Removes a node from the ring.
  """
  @spec remove_node(t(), node_id()) :: t()
  def remove_node(%__MODULE__{ring: ring, nodes: nodes}, node_id) when is_binary(node_id) do
    updated_ring = Enum.reject(ring, fn {_, id} -> id == node_id end)
    %__MODULE__{ring: updated_ring, nodes: MapSet.delete(nodes, node_id)}
  end

  @doc """
  Returns all node identifiers currently in the ring.
  """
  @spec nodes(t()) :: [node_id()]
  def nodes(%__MODULE__{nodes: n}), do: MapSet.to_list(n)

  @doc """
  Returns the count of real (non-virtual) nodes in the ring.
  """
  @spec node_count(t()) :: non_neg_integer()
  def node_count(%__MODULE__{nodes: n}), do: MapSet.size(n)

  @doc """
  Returns the N nodes responsible for a key (for replication scenarios).
  """
  @spec nodes_for(t(), String.t(), pos_integer()) :: {:ok, [node_id()]} | {:error, :empty_ring}
  def nodes_for(%__MODULE__{ring: []}, _key, _n), do: {:error, :empty_ring}

  def nodes_for(%__MODULE__{ring: ring, nodes: nodes} = r, key, n)
      when is_integer(n) and n > 0 do
    count = min(n, MapSet.size(nodes))
    hash = hash_key(key)

    start_idx =
      ring
      |> Enum.find_index(fn {point, _} -> point >= hash end)
      |> then(&(&1 || 0))

    result =
      Stream.iterate(start_idx, fn i -> rem(i + 1, length(ring)) end)
      |> Stream.map(fn i -> elem(Enum.at(ring, i), 1) end)
      |> Stream.uniq()
      |> Enum.take(count)

    {:ok, result}
  end

  defp virtual_points(node_id) do
    Enum.map(1..@virtual_nodes, fn i ->
      {hash_key("#{node_id}:#{i}"), node_id}
    end)
  end

  defp hash_key(key) do
    <<hash::unsigned-integer-32, _::binary>> = :crypto.hash(:md5, key)
    hash
  end
end
```
