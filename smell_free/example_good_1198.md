```elixir
defmodule Dependencies.Resolver do
  @moduledoc """
  Resolves a dependency graph into a topologically sorted execution
  order. Detects cycles and returns structured errors that identify
  the nodes involved in the circular dependency.
  """

  @type node_id :: atom()
  @type graph :: %{node_id() => [node_id()]}
  @type sort_result :: {:ok, [node_id()]} | {:error, {:cycle_detected, [node_id()]}}

  @spec resolve(graph()) :: sort_result()
  def resolve(graph) when is_map(graph) do
    nodes = Map.keys(graph)

    nodes
    |> Enum.reduce_while({[], MapSet.new(), MapSet.new()}, fn node, {order, visited, in_stack} ->
      case visit(node, graph, order, visited, in_stack) do
        {:ok, new_order, new_visited} -> {:cont, {new_order, new_visited, in_stack}}
        {:error, _} = err -> {:halt, err}
      end
    end)
    |> case do
      {order, _, _} -> {:ok, Enum.reverse(order)}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec dependencies_of(node_id(), graph()) :: {:ok, [node_id()]} | {:error, :not_found}
  def dependencies_of(node, graph) when is_atom(node) do
    case Map.fetch(graph, node) do
      {:ok, deps} -> {:ok, deps}
      :error -> {:error, :not_found}
    end
  end

  @spec dependents_of(node_id(), graph()) :: [node_id()]
  def dependents_of(node, graph) when is_atom(node) do
    Enum.filter(Map.keys(graph), fn candidate ->
      node in Map.get(graph, candidate, [])
    end)
  end

  @spec visit(node_id(), graph(), [node_id()], MapSet.t(), MapSet.t()) ::
          {:ok, [node_id()], MapSet.t()} | {:error, {:cycle_detected, [node_id()]}}
  defp visit(node, graph, order, visited, in_stack) do
    cond do
      MapSet.member?(in_stack, node) ->
        {:error, {:cycle_detected, [node | MapSet.to_list(in_stack)]}}

      MapSet.member?(visited, node) ->
        {:ok, order, visited}

      true ->
        explore(node, graph, order, visited, in_stack)
    end
  end

  @spec explore(node_id(), graph(), [node_id()], MapSet.t(), MapSet.t()) ::
          {:ok, [node_id()], MapSet.t()} | {:error, {:cycle_detected, [node_id()]}}
  defp explore(node, graph, order, visited, in_stack) do
    deps = Map.get(graph, node, [])
    new_stack = MapSet.put(in_stack, node)

    deps
    |> Enum.reduce_while({order, visited}, fn dep, {acc_order, acc_visited} ->
      case visit(dep, graph, acc_order, acc_visited, new_stack) do
        {:ok, new_order, new_visited} -> {:cont, {new_order, new_visited}}
        {:error, _} = err -> {:halt, err}
      end
    end)
    |> case do
      {new_order, new_visited} ->
        {:ok, [node | new_order], MapSet.put(new_visited, node)}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
```
