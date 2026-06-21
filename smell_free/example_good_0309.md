```elixir
defmodule Graph.DependencyResolver do
  @moduledoc """
  Resolves a directed acyclic dependency graph into a topologically sorted
  execution order. Each node declares its direct dependencies. The resolver
  detects cycles and returns a descriptive error rather than looping
  indefinitely. Nodes with no dependencies may be executed concurrently;
  the resolver groups them into ordered execution levels.
  """

  @type node_id :: atom() | String.t()
  @type graph :: %{node_id() => [node_id()]}
  @type execution_level :: [node_id()]
  @type resolve_result :: {:ok, [execution_level()]} | {:error, {:cycle_detected, [node_id()]}}

  @doc """
  Resolves `graph` into levels of nodes that can be executed concurrently.
  Returns a list of levels in execution order, or an error if a cycle exists.
  """
  @spec resolve(graph()) :: resolve_result()
  def resolve(graph) when is_map(graph) do
    in_degrees = compute_in_degrees(graph)
    sort_kahn(graph, in_degrees, [], 0)
  end

  @doc "Returns the transitive dependencies of `node_id` in `graph`."
  @spec transitive_deps(graph(), node_id()) :: {:ok, MapSet.t()} | {:error, {:cycle_detected, [node_id()]}}
  def transitive_deps(graph, node_id) do
    collect_deps(graph, [node_id], MapSet.new(), MapSet.new())
  end

  defp compute_in_degrees(graph) do
    all_nodes = Map.keys(graph)
    base = Map.new(all_nodes, fn n -> {n, 0} end)

    Enum.reduce(graph, base, fn {_node, deps}, acc ->
      Enum.reduce(deps, acc, fn dep, inner ->
        Map.update(inner, dep, 1, &(&1 + 1))
      end)
    end)
  end

  defp sort_kahn(graph, in_degrees, levels, resolved_count) do
    ready = in_degrees |> Enum.filter(fn {_n, d} -> d == 0 end) |> Enum.map(fn {n, _} -> n end)

    case ready do
      [] when resolved_count < map_size(graph) ->
        cycle = find_cycle(graph)
        {:error, {:cycle_detected, cycle}}

      [] ->
        {:ok, Enum.reverse(levels)}

      nodes ->
        new_in_degrees =
          Enum.reduce(nodes, in_degrees, fn node, acc ->
            deps = Map.get(graph, node, [])
            acc_without_node = Map.delete(acc, node)
            Enum.reduce(deps, acc_without_node, fn dep, inner ->
              Map.update!(inner, dep, &(&1 - 1))
            end)
          end)

        sort_kahn(graph, new_in_degrees, [nodes | levels], resolved_count + length(nodes))
    end
  end

  defp find_cycle(graph) do
    Enum.find_value(Map.keys(graph), fn start ->
      case dfs_cycle(graph, start, [start], MapSet.new([start])) do
        {:cycle, path} -> path
        :no_cycle -> nil
      end
    end) || []
  end

  defp dfs_cycle(graph, node, path, visited) do
    deps = Map.get(graph, node, [])

    Enum.find_value(deps, :no_cycle, fn dep ->
      if MapSet.member?(visited, dep) do
        {:cycle, Enum.reverse([dep | path])}
      else
        dfs_cycle(graph, dep, [dep | path], MapSet.put(visited, dep))
      end
    end)
  end

  defp collect_deps(_graph, [], acc, _visiting), do: {:ok, acc}

  defp collect_deps(graph, [node | rest], acc, visiting) do
    if MapSet.member?(visiting, node) do
      {:error, {:cycle_detected, [node]}}
    else
      deps = Map.get(graph, node, [])
      new_deps = Enum.reject(deps, &MapSet.member?(acc, &1))
      new_acc = Enum.reduce(deps, acc, &MapSet.put(&2, &1))
      collect_deps(graph, new_deps ++ rest, new_acc, MapSet.put(visiting, node))
    end
  end
end
```
