```elixir
defmodule Network.Topology.GraphBuilder do
  @moduledoc """
  Builds and queries an in-memory directed graph of network nodes and edges.
  Supports adjacency lookup, cycle detection, and shortest-hop path finding.
  """

  @type node_id :: String.t()
  @type edge :: %{from: node_id(), to: node_id(), weight: pos_integer()}
  @type graph :: %{nodes: MapSet.t(node_id()), edges: [edge()]}

  @doc """
  Returns a new empty graph.
  """
  @spec new() :: graph()
  def new, do: %{nodes: MapSet.new(), edges: []}

  @doc """
  Adds a node to the graph. Returns the updated graph unchanged if already present.
  """
  @spec add_node(graph(), node_id()) :: {:ok, graph()} | {:error, String.t()}
  def add_node(graph, node_id) when is_binary(node_id) and node_id != "" do
    {:ok, %{graph | nodes: MapSet.put(graph.nodes, node_id)}}
  end

  def add_node(_graph, _node_id), do: {:error, "node_id must be a non-empty string"}

  @doc """
  Adds a directed weighted edge. Both nodes must exist in the graph.
  """
  @spec add_edge(graph(), node_id(), node_id(), pos_integer()) ::
          {:ok, graph()} | {:error, String.t()}
  def add_edge(graph, from, to, weight)
      when is_binary(from) and is_binary(to) and is_integer(weight) and weight > 0 do
    with :ok <- assert_node_exists(graph, from),
         :ok <- assert_node_exists(graph, to) do
      edge = %{from: from, to: to, weight: weight}
      {:ok, %{graph | edges: [edge | graph.edges]}}
    end
  end

  def add_edge(_graph, _from, _to, _weight), do: {:error, "invalid edge parameters"}

  @doc """
  Returns the list of nodes directly reachable from `node_id`.
  """
  @spec neighbours(graph(), node_id()) :: [node_id()]
  def neighbours(graph, node_id) when is_binary(node_id) do
    graph.edges
    |> Enum.filter(fn e -> e.from == node_id end)
    |> Enum.map(fn e -> e.to end)
  end

  @doc """
  Returns the shortest path (fewest hops) from `source` to `target` using BFS.
  Returns `{:ok, path}` or `{:error, :no_path}`.
  """
  @spec shortest_path(graph(), node_id(), node_id()) ::
          {:ok, [node_id()]} | {:error, :no_path}
  def shortest_path(graph, source, target)
      when is_binary(source) and is_binary(target) do
    bfs(graph, :queue.in({source, [source]}, :queue.new()), MapSet.new([source]), target)
  end

  @doc """
  Returns true if the graph contains at least one cycle, false otherwise.
  """
  @spec cyclic?(graph()) :: boolean()
  def cyclic?(graph) do
    graph.nodes
    |> MapSet.to_list()
    |> Enum.any?(fn node -> has_cycle_from?(graph, node, MapSet.new(), MapSet.new()) end)
  end

  defp assert_node_exists(graph, node_id) do
    if MapSet.member?(graph.nodes, node_id) do
      :ok
    else
      {:error, "node #{inspect(node_id)} does not exist in the graph"}
    end
  end

  defp bfs(_graph, queue, _visited, target) when :queue.is_empty(queue) do
    {:error, :no_path}
  end

  defp bfs(graph, queue, visited, target) do
    {{:value, {current, path}}, rest} = :queue.out(queue)

    if current == target do
      {:ok, path}
    else
      new_neighbours =
        neighbours(graph, current)
        |> Enum.reject(fn n -> MapSet.member?(visited, n) end)

      new_visited = Enum.reduce(new_neighbours, visited, fn n, acc -> MapSet.put(acc, n) end)

      new_queue =
        Enum.reduce(new_neighbours, rest, fn n, q -> :queue.in({n, path ++ [n]}, q) end)

      bfs(graph, new_queue, new_visited, target)
    end
  end

  defp has_cycle_from?(graph, node, visiting, visited) do
    cond do
      MapSet.member?(visiting, node) -> true
      MapSet.member?(visited, node) -> false
      true ->
        new_visiting = MapSet.put(visiting, node)

        result =
          neighbours(graph, node)
          |> Enum.any?(fn n -> has_cycle_from?(graph, n, new_visiting, visited) end)

        result
    end
  end
end
```
