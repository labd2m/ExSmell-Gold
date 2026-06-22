```elixir
defmodule Graph.DependencyResolver do
  @moduledoc """
  Resolves a directed acyclic dependency graph into a topologically ordered execution plan.
  Detects circular dependencies and reports the cycle path on failure.
  """

  @type node_id :: String.t()
  @type graph :: %{node_id() => [node_id()]}
  @type resolution :: {:ok, [node_id()]} | {:error, :cycle_detected, [node_id()]}

  @spec resolve(graph()) :: resolution()
  def resolve(graph) when is_map(graph) do
    nodes = Map.keys(graph)
    topological_sort(nodes, graph)
  end

  @spec execution_levels(graph()) :: {:ok, [[node_id()]]} | {:error, :cycle_detected, [node_id()]}
  def execution_levels(graph) when is_map(graph) do
    with {:ok, sorted} <- resolve(graph) do
      levels = group_into_levels(sorted, graph)
      {:ok, levels}
    end
  end

  @spec reachable_from(node_id(), graph()) :: MapSet.t(node_id())
  def reachable_from(start, graph) when is_binary(start) and is_map(graph) do
    traverse_reachable(start, graph, MapSet.new())
  end

  @spec topological_sort([node_id()], graph()) :: resolution()
  defp topological_sort(nodes, graph) do
    initial_state = %{visited: MapSet.new(), temp: MapSet.new(), result: [], path: []}

    Enum.reduce_while(nodes, {:ok, initial_state}, fn node, {:ok, state} ->
      if MapSet.member?(state.visited, node) do
        {:cont, {:ok, state}}
      else
        case visit(node, graph, state) do
          {:ok, new_state} -> {:cont, {:ok, new_state}}
          {:error, :cycle_detected, cycle} -> {:halt, {:error, :cycle_detected, cycle}}
        end
      end
    end)
    |> case do
      {:ok, state} -> {:ok, Enum.reverse(state.result)}
      error -> error
    end
  end

  @spec visit(node_id(), graph(), map()) :: {:ok, map()} | {:error, :cycle_detected, [node_id()]}
  defp visit(node, graph, state) do
    if MapSet.member?(state.temp, node) do
      cycle = extract_cycle(node, state.path)
      {:error, :cycle_detected, cycle}
    else
      new_state = %{state | temp: MapSet.put(state.temp, node), path: [node | state.path]}
      deps = Map.get(graph, node, [])

      case visit_dependencies(deps, graph, new_state) do
        {:ok, after_deps} ->
          final = %{after_deps |
            visited: MapSet.put(after_deps.visited, node),
            temp: MapSet.delete(after_deps.temp, node),
            path: tl(after_deps.path),
            result: [node | after_deps.result]
          }
          {:ok, final}

        error ->
          error
      end
    end
  end

  @spec visit_dependencies([node_id()], graph(), map()) ::
          {:ok, map()} | {:error, :cycle_detected, [node_id()]}
  defp visit_dependencies(deps, graph, state) do
    Enum.reduce_while(deps, {:ok, state}, fn dep, {:ok, acc} ->
      if MapSet.member?(acc.visited, dep) do
        {:cont, {:ok, acc}}
      else
        case visit(dep, graph, acc) do
          {:ok, new_state} -> {:cont, {:ok, new_state}}
          error -> {:halt, error}
        end
      end
    end)
  end

  @spec extract_cycle(node_id(), [node_id()]) :: [node_id()]
  defp extract_cycle(node, path) do
    cycle_start = Enum.find_index(path, &(&1 == node))
    path |> Enum.take(cycle_start + 1) |> Enum.reverse()
  end

  @spec group_into_levels([node_id()], graph()) :: [[node_id()]]
  defp group_into_levels(sorted, graph) do
    Enum.reduce(sorted, {%{}, %{}}, fn node, {levels, depths} ->
      depth = compute_depth(node, graph, depths)
      updated_levels = Map.update(levels, depth, [node], &[node | &1])
      {updated_levels, Map.put(depths, node, depth)}
    end)
    |> elem(0)
    |> Enum.sort_by(fn {depth, _} -> depth end)
    |> Enum.map(fn {_, nodes} -> nodes end)
  end

  @spec compute_depth(node_id(), graph(), map()) :: non_neg_integer()
  defp compute_depth(node, graph, depths) do
    deps = Map.get(graph, node, [])

    if Enum.empty?(deps) do
      0
    else
      max_dep_depth = deps |> Enum.map(&Map.get(depths, &1, 0)) |> Enum.max()
      max_dep_depth + 1
    end
  end

  @spec traverse_reachable(node_id(), graph(), MapSet.t()) :: MapSet.t(node_id())
  defp traverse_reachable(node, graph, visited) do
    if MapSet.member?(visited, node) do
      visited
    else
      new_visited = MapSet.put(visited, node)

      Map.get(graph, node, [])
      |> Enum.reduce(new_visited, &traverse_reachable(&1, graph, &2))
    end
  end
end
```
