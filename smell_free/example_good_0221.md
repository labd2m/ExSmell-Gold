```elixir
defmodule MyApp.Graph.DependencyResolver do
  @moduledoc """
  Resolves a directed dependency graph using Kahn's topological sort
  algorithm. Accepts a map of node identifiers to lists of their
  direct dependencies and returns an ordered execution plan or a
  structured error when cycles are detected.

  Suitable for resolving task graphs, build pipelines, migration chains,
  and plugin load orders.
  """

  @type node_id :: term()
  @type graph :: %{node_id() => [node_id()]}
  @type resolution_error :: {:error, {:cycle_detected, involving: [node_id()]}}

  @doc """
  Returns a topologically sorted list of nodes from `graph` such that
  every node appears after all of its dependencies.

  Returns `{:error, {:cycle_detected, involving: nodes}}` if the graph
  contains one or more cycles, listing the nodes involved.
  """
  @spec resolve(graph()) :: {:ok, [node_id()]} | resolution_error()
  def resolve(graph) when is_map(graph) do
    in_degrees = compute_in_degrees(graph)
    queue = initial_queue(in_degrees)
    do_resolve(queue, graph, in_degrees, [])
  end

  @doc """
  Returns `true` when `graph` is acyclic (contains no dependency cycles).
  """
  @spec acyclic?(graph()) :: boolean()
  def acyclic?(graph), do: match?({:ok, _}, resolve(graph))

  @doc """
  Returns the nodes that have no dependencies — the roots of the graph.
  These can be scheduled immediately without waiting for any predecessor.
  """
  @spec roots(graph()) :: [node_id()]
  def roots(graph) when is_map(graph) do
    dependents = MapSet.new(Map.keys(graph))

    all_deps =
      graph
      |> Map.values()
      |> List.flatten()
      |> MapSet.new()

    MapSet.difference(dependents, all_deps) |> MapSet.to_list()
  end

  @spec compute_in_degrees(graph()) :: %{node_id() => non_neg_integer()}
  defp compute_in_degrees(graph) do
    base = Map.new(graph, fn {node, _} -> {node, 0} end)

    Enum.reduce(graph, base, fn {_node, deps}, acc ->
      Enum.reduce(deps, acc, fn dep, inner_acc ->
        Map.update(inner_acc, dep, 1, &(&1 + 1))
      end)
    end)
  end

  @spec initial_queue(%{node_id() => non_neg_integer()}) :: :queue.queue()
  defp initial_queue(in_degrees) do
    in_degrees
    |> Enum.filter(fn {_, degree} -> degree == 0 end)
    |> Enum.map(&elem(&1, 0))
    |> Enum.reduce(:queue.new(), &:queue.in(&1, &2))
  end

  @spec do_resolve(:queue.queue(), graph(), %{node_id() => non_neg_integer()}, [node_id()]) ::
          {:ok, [node_id()]} | resolution_error()
  defp do_resolve(queue, graph, in_degrees, sorted) do
    case :queue.out(queue) do
      {:empty, _} ->
        if map_size(in_degrees) == length(sorted) do
          {:ok, Enum.reverse(sorted)}
        else
          cyclic_nodes = find_cyclic_nodes(in_degrees, sorted)
          {:error, {:cycle_detected, involving: cyclic_nodes}}
        end

      {{:value, node}, rest_queue} ->
        {new_queue, new_degrees} = process_node(node, rest_queue, graph, in_degrees)
        do_resolve(new_queue, graph, new_degrees, [node | sorted])
    end
  end

  @spec process_node(node_id(), :queue.queue(), graph(), %{node_id() => non_neg_integer()}) ::
          {:queue.queue(), %{node_id() => non_neg_integer()}}
  defp process_node(node, queue, graph, in_degrees) do
    dependents = Map.get(graph, node, [])

    Enum.reduce(dependents, {queue, in_degrees}, fn dep, {q, degrees} ->
      new_degree = Map.get(degrees, dep, 1) - 1
      updated = Map.put(degrees, dep, new_degree)
      updated_q = if new_degree == 0, do: :queue.in(dep, q), else: q
      {updated_q, updated}
    end)
  end

  @spec find_cyclic_nodes(%{node_id() => non_neg_integer()}, [node_id()]) :: [node_id()]
  defp find_cyclic_nodes(in_degrees, sorted) do
    sorted_set = MapSet.new(sorted)
    in_degrees |> Map.keys() |> Enum.reject(&MapSet.member?(sorted_set, &1))
  end
end
```
