# File: `example_good_233.md`

```elixir
defmodule Graph.DependencyResolver do
  @moduledoc """
  Resolves ordered execution plans from a directed acyclic dependency graph
  using Kahn's topological sort algorithm.

  Nodes are arbitrary terms; edges declare that one node depends on another
  and must therefore be executed after it. Cycles are detected and reported
  with the offending nodes rather than producing an incorrect ordering.
  """

  @type node_id :: term()
  @type edge :: {node_id(), node_id()}

  @type resolve_result ::
          {:ok, [node_id()]}
          | {:error, {:cycle_detected, [node_id()]}}

  @doc """
  Produces a linear execution order for `nodes` respecting the constraints
  expressed in `edges`.

  Each edge `{a, b}` means "node `a` depends on node `b`" — `b` must
  appear before `a` in the output.

  Returns `{:ok, ordered_nodes}` or `{:error, {:cycle_detected, cycle_members}}`
  when the graph contains a cycle.
  """
  @spec resolve([node_id()], [edge()]) :: resolve_result()
  def resolve(nodes, edges) when is_list(nodes) and is_list(edges) do
    in_degree = compute_in_degrees(nodes, edges)
    adjacency = build_adjacency(edges)

    queue = for {node, 0} <- in_degree, do: node

    kahn_sort(queue, in_degree, adjacency, [])
    |> case do
      {:ok, ordered} when length(ordered) == length(nodes) ->
        {:ok, ordered}

      {:ok, ordered} ->
        cycle_members = nodes -- ordered
        {:error, {:cycle_detected, cycle_members}}

      {:error, _} = error ->
        error
    end
  end

  @doc """
  Returns all nodes that directly or transitively depend on `target`.
  """
  @spec dependents([node_id()], [edge()], node_id()) :: [node_id()]
  def dependents(nodes, edges, target) when is_list(nodes) and is_list(edges) do
    reverse_adj = build_reverse_adjacency(edges)
    reachable(target, reverse_adj, MapSet.new(), [])
    |> Enum.filter(&(&1 != target))
  end

  @doc """
  Returns all nodes that `source` directly or transitively depends on.
  """
  @spec dependencies([node_id()], [edge()], node_id()) :: [node_id()]
  def dependencies(nodes, edges, source) when is_list(nodes) and is_list(edges) do
    adjacency = build_adjacency(edges)
    reachable(source, adjacency, MapSet.new(), [])
    |> Enum.filter(&(&1 != source))
  end

  @doc """
  Returns `true` when the graph defined by `edges` contains at least one cycle.
  """
  @spec cyclic?([node_id()], [edge()]) :: boolean()
  def cyclic?(nodes, edges) when is_list(nodes) and is_list(edges) do
    case resolve(nodes, edges) do
      {:ok, _} -> false
      {:error, {:cycle_detected, _}} -> true
    end
  end

  defp compute_in_degrees(nodes, edges) do
    base = Map.new(nodes, &{&1, 0})

    Enum.reduce(edges, base, fn {dependent, _dependency}, acc ->
      Map.update(acc, dependent, 1, &(&1 + 1))
    end)
  end

  defp build_adjacency(edges) do
    Enum.reduce(edges, %{}, fn {dependent, dependency}, acc ->
      Map.update(acc, dependency, [dependent], &[dependent | &1])
    end)
  end

  defp build_reverse_adjacency(edges) do
    Enum.reduce(edges, %{}, fn {dependent, dependency}, acc ->
      Map.update(acc, dependent, [dependency], &[dependency | &1])
    end)
  end

  defp kahn_sort([], in_degree, _adj, ordered) do
    {:ok, Enum.reverse(ordered)}
  end

  defp kahn_sort([node | rest], in_degree, adjacency, ordered) do
    successors = Map.get(adjacency, node, [])

    {new_queue_additions, updated_degrees} =
      Enum.reduce(successors, {[], in_degree}, fn succ, {queue_acc, degrees} ->
        new_degree = Map.get(degrees, succ, 0) - 1
        updated = Map.put(degrees, succ, new_degree)

        if new_degree == 0 do
          {[succ | queue_acc], updated}
        else
          {queue_acc, updated}
        end
      end)

    kahn_sort(rest ++ new_queue_additions, updated_degrees, adjacency, [node | ordered])
  end

  defp reachable(node, adjacency, visited, acc) do
    if MapSet.member?(visited, node) do
      acc
    else
      new_visited = MapSet.put(visited, node)
      neighbours = Map.get(adjacency, node, [])

      Enum.reduce(neighbours, [node | acc], fn neighbour, acc2 ->
        reachable(neighbour, adjacency, new_visited, acc2)
      end)
    end
  end
end
```
