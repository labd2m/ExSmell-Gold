```elixir
defmodule Graph.Analysis.PageRankCalculator do
  @moduledoc """
  Computes PageRank scores for nodes in a directed weighted graph.

  Uses the iterative power-method approximation with configurable damping
  factor and convergence tolerance. Suitable for link analysis, social
  network influence scoring, and recommendation graphs.
  """

  @type node_id :: String.t()
  @type edge :: %{from: node_id(), to: node_id(), weight: float()}
  @type scores :: %{node_id() => float()}

  @default_damping 0.85
  @default_tolerance 1.0e-6
  @default_max_iterations 100

  @type rank_opts :: [
          damping: float(),
          tolerance: float(),
          max_iterations: pos_integer()
        ]

  @doc """
  Computes PageRank scores for all nodes in the graph.

  Returns `{:ok, scores}` where scores is a map of node IDs to rank values,
  or `{:error, :no_nodes}` for an empty graph.
  """
  @spec compute([node_id()], [edge()], rank_opts()) ::
          {:ok, scores()} | {:error, :no_nodes}
  def compute([], _edges, _opts), do: {:error, :no_nodes}

  def compute(nodes, edges, opts \\ []) do
    damping = Keyword.get(opts, :damping, @default_damping)
    tolerance = Keyword.get(opts, :tolerance, @default_tolerance)
    max_iter = Keyword.get(opts, :max_iterations, @default_max_iterations)

    n = length(nodes)
    initial_score = 1.0 / n
    scores = Map.new(nodes, &{&1, initial_score})

    out_weights = build_out_weight_index(edges)
    in_edges = build_in_edge_index(edges)

    result = iterate(scores, nodes, in_edges, out_weights, damping, tolerance, max_iter, 0)
    {:ok, result}
  end

  defp iterate(scores, _nodes, _in_edges, _out_weights, _d, _tol, max_iter, max_iter) do
    scores
  end

  defp iterate(scores, nodes, in_edges, out_weights, damping, tolerance, max_iter, iteration) do
    n = length(nodes)
    base = (1.0 - damping) / n

    new_scores =
      Map.new(nodes, fn node ->
        incoming = Map.get(in_edges, node, [])

        contribution =
          Enum.reduce(incoming, 0.0, fn %{from: from, weight: w}, acc ->
            total_out = Map.get(out_weights, from, 1.0)
            acc + scores[from] * (w / total_out)
          end)

        {node, base + damping * contribution}
      end)

    if converged?(scores, new_scores, tolerance) do
      new_scores
    else
      iterate(new_scores, nodes, in_edges, out_weights, damping, tolerance, max_iter, iteration + 1)
    end
  end

  defp converged?(old_scores, new_scores, tolerance) do
    old_scores
    |> Enum.all?(fn {node, old_val} ->
      abs(old_val - Map.fetch!(new_scores, node)) < tolerance
    end)
  end

  defp build_out_weight_index(edges) do
    edges
    |> Enum.group_by(& &1.from)
    |> Map.new(fn {from, outgoing} ->
      total_weight = Enum.reduce(outgoing, 0.0, &(&1.weight + &2))
      {from, total_weight}
    end)
  end

  defp build_in_edge_index(edges) do
    Enum.reduce(edges, %{}, fn edge, acc ->
      Map.update(acc, edge.to, [edge], &[edge | &1])
    end)
  end
end
```
