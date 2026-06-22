```elixir
defmodule Routing.HashRing do
  @moduledoc """
  Implements a consistent hash ring for distributing keys across a set of
  named nodes. Virtual nodes ensure even distribution; adding or removing
  a physical node only remaps a proportional fraction of keys.
  """

  @type node_name :: String.t()
  @type ring :: %{sorted_hashes: [integer()], map: %{integer() => node_name()}}

  @default_vnodes 150

  @spec new([node_name()], keyword()) :: ring()
  def new(nodes, opts \\ []) when is_list(nodes) do
    vnodes = Keyword.get(opts, :vnodes, @default_vnodes)

    {sorted, map} =
      nodes
      |> Enum.flat_map(fn node -> Enum.map(1..vnodes, &{hash("#{node}:#{&1}"), node}) end)
      |> Enum.reduce({[], %{}}, fn {h, node}, {hashes, acc_map} ->
        {[h | hashes], Map.put(acc_map, h, node)}
      end)

    %{sorted_hashes: Enum.sort(sorted), map: map}
  end

  @spec add_node(ring(), node_name(), keyword()) :: ring()
  def add_node(%{sorted_hashes: hashes, map: map} = _ring, node, opts \\ []) do
    vnodes = Keyword.get(opts, :vnodes, @default_vnodes)

    new_entries = Enum.map(1..vnodes, fn i -> {hash("#{node}:#{i}"), node} end)

    updated_map = Enum.reduce(new_entries, map, fn {h, n}, acc -> Map.put(acc, h, n) end)
    new_hashes = (Enum.map(new_entries, &elem(&1, 0)) ++ hashes) |> Enum.sort()

    %{sorted_hashes: new_hashes, map: updated_map}
  end

  @spec remove_node(ring(), node_name()) :: ring()
  def remove_node(%{sorted_hashes: hashes, map: map}, node) do
    stale_hashes = map |> Enum.filter(fn {_, n} -> n == node end) |> Enum.map(&elem(&1, 0))
    stale_set = MapSet.new(stale_hashes)

    updated_map = Map.reject(map, fn {h, _} -> MapSet.member?(stale_set, h) end)
    updated_hashes = Enum.reject(hashes, &MapSet.member?(stale_set, &1))

    %{sorted_hashes: updated_hashes, map: updated_map}
  end

  @spec locate(ring(), String.t()) :: {:ok, node_name()} | {:error, :empty_ring}
  def locate(%{sorted_hashes: []}, _key), do: {:error, :empty_ring}

  def locate(%{sorted_hashes: hashes, map: map}, key) when is_binary(key) do
    target = hash(key)

    node =
      case Enum.find(hashes, &(&1 >= target)) do
        nil -> Map.fetch!(map, List.first(hashes))
        h -> Map.fetch!(map, h)
      end

    {:ok, node}
  end

  @spec locate_n(ring(), String.t(), pos_integer()) :: {:ok, [node_name()]} | {:error, :empty_ring}
  def locate_n(%{sorted_hashes: []}, _key, _n), do: {:error, :empty_ring}

  def locate_n(%{sorted_hashes: hashes, map: map} = ring, key, n) do
    max_nodes = ring |> unique_nodes() |> length()
    count = min(n, max_nodes)

    target = hash(key)
    rotated = rotate_ring(hashes, target)

    nodes =
      rotated
      |> Enum.map(&Map.fetch!(map, &1))
      |> Enum.uniq()
      |> Enum.take(count)

    {:ok, nodes}
  end

  @spec unique_nodes(ring()) :: [node_name()]
  def unique_nodes(%{map: map}) do
    map |> Map.values() |> Enum.uniq()
  end

  @spec node_count(ring()) :: non_neg_integer()
  def node_count(ring), do: length(unique_nodes(ring))

  @spec hash(String.t()) :: integer()
  defp hash(key) do
    <<value::unsigned-32, _::binary>> = :crypto.hash(:sha256, key)
    value
  end

  @spec rotate_ring([integer()], integer()) :: [integer()]
  defp rotate_ring(hashes, target) do
    {after_target, before_target} = Enum.split_while(hashes, &(&1 < target))
    before_target ++ after_target
  end
end
```
