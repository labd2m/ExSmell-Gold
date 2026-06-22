```elixir
defmodule Graph.Edge do
  @moduledoc """
  A directed, optionally-weighted edge connecting two vertices in a graph.
  """

  @enforce_keys [:from, :to]
  defstruct [:from, :to, weight: 1]

  @type vertex :: term()
  @type t :: %__MODULE__{from: vertex(), to: vertex(), weight: number()}

  @spec new(vertex(), vertex(), number()) :: t()
  def new(from, to, weight \\ 1), do: %__MODULE__{from: from, to: to, weight: weight}
end

defmodule Graph.Adjacency do
  @moduledoc """
  An adjacency-list representation of a directed weighted graph.
  Supports incremental construction and efficient neighbour lookups.
  """

  alias Graph.Edge

  @type vertex :: Edge.vertex()
  @type t :: %__MODULE__{adjacency: %{vertex() => list(Edge.t())}, directed: boolean()}

  defstruct adjacency: %{}, directed: true

  @spec new(boolean()) :: t()
  def new(directed \\ true) when is_boolean(directed) do
    %__MODULE__{directed: directed}
  end

  @spec add_vertex(t(), vertex()) :: t()
  def add_vertex(%__MODULE__{adjacency: adj} = graph, vertex) do
    %{graph | adjacency: Map.put_new(adj, vertex, [])}
  end

  @spec add_edge(t(), Edge.t()) :: t()
  def add_edge(%__MODULE__{} = graph, %Edge{from: from, to: to} = edge) do
    graph
    |> ensure_vertex(from)
    |> ensure_vertex(to)
    |> insert_edge(edge)
    |> maybe_insert_reverse(edge)
  end

  @spec neighbours(t(), vertex()) :: list(Edge.t())
  def neighbours(%__MODULE__{adjacency: adj}, vertex) do
    Map.get(adj, vertex, [])
  end

  @spec vertices(t()) :: list(vertex())
  def vertices(%__MODULE__{adjacency: adj}), do: Map.keys(adj)

  @spec has_vertex?(t(), vertex()) :: boolean()
  def has_vertex?(%__MODULE__{adjacency: adj}, vertex), do: Map.has_key?(adj, vertex)

  defp ensure_vertex(%__MODULE__{adjacency: adj} = graph, vertex) do
    %{graph | adjacency: Map.put_new(adj, vertex, [])}
  end

  defp insert_edge(%__MODULE__{adjacency: adj} = graph, %Edge{from: from} = edge) do
    %{graph | adjacency: Map.update!(adj, from, &[edge | &1])}
  end

  defp maybe_insert_reverse(%__MODULE__{directed: true} = graph, _edge), do: graph

  defp maybe_insert_reverse(%__MODULE__{adjacency: adj} = graph, %Edge{from: from, to: to, weight: w}) do
    reverse = Edge.new(to, from, w)
    %{graph | adjacency: Map.update!(adj, to, &[reverse | &1])}
  end
end

defmodule Graph.Pathfinder do
  @moduledoc """
  Shortest-path algorithms over a `Graph.Adjacency` structure.
  Dijkstra's algorithm is used for non-negative weighted graphs.
  Returns the optimal path and its total cost.
  """

  alias Graph.{Adjacency, Edge}

  @type vertex :: Edge.vertex()
  @type path_result :: {:ok, list(vertex()), number()} | {:error, :no_path}

  @spec shortest_path(Adjacency.t(), vertex(), vertex()) :: path_result()
  def shortest_path(%Adjacency{} = graph, source, target) do
    unless Adjacency.has_vertex?(graph, source) and Adjacency.has_vertex?(graph, target) do
      {:error, :no_path}
    else
      dijkstra(graph, source, target)
    end
  end

  defp dijkstra(graph, source, target) do
    dist = %{source => 0}
    prev = %{}
    unvisited = MapSet.new(Adjacency.vertices(graph))

    {final_dist, final_prev} = relax_all(graph, unvisited, dist, prev)

    if Map.has_key?(final_dist, target) do
      path = reconstruct_path(final_prev, source, target)
      {:ok, path, Map.fetch!(final_dist, target)}
    else
      {:error, :no_path}
    end
  end

  defp relax_all(_graph, unvisited, dist, prev) when map_size(dist) == 0 or MapSet.size(unvisited) == 0 do
    {dist, prev}
  end

  defp relax_all(graph, unvisited, dist, prev) do
    current = unvisited |> Enum.filter(&Map.has_key?(dist, &1)) |> Enum.min_by(&Map.fetch!(dist, &1), fn -> nil end)

    if is_nil(current) do
      {dist, prev}
    else
      new_unvisited = MapSet.delete(unvisited, current)
      current_dist = Map.fetch!(dist, current)

      {new_dist, new_prev} =
        graph
        |> Adjacency.neighbours(current)
        |> Enum.reduce({dist, prev}, fn %Edge{to: neighbour, weight: w}, {d, p} ->
          alt = current_dist + w
          if alt < Map.get(d, neighbour, :infinity) do
            {Map.put(d, neighbour, alt), Map.put(p, neighbour, current)}
          else
            {d, p}
          end
        end)

      relax_all(graph, new_unvisited, new_dist, new_prev)
    end
  end

  defp reconstruct_path(prev, source, target) do
    build_path(prev, source, target, [target])
  end

  defp build_path(_prev, source, source, acc), do: acc

  defp build_path(prev, source, current, acc) do
    parent = Map.fetch!(prev, current)
    build_path(prev, source, parent, [parent | acc])
  end
end
```
