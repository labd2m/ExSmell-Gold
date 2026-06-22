```elixir
defmodule Catalog.RecommendationEngine do
  @moduledoc """
  Generates product recommendations based on category co-occurrence in
  historical orders. Items that appear together frequently in completed
  orders receive higher co-occurrence scores. The engine is stateless and
  pure; the co-occurrence matrix is built from caller-supplied order data,
  making results fully reproducible in tests without database fixtures.
  """

  @type product_id :: String.t()
  @type order_items :: [product_id()]
  @type co_occurrence_matrix :: %{{product_id(), product_id()} => non_neg_integer()}
  @type recommendation :: %{product_id: product_id(), score: non_neg_integer()}

  @doc """
  Builds a co-occurrence matrix from a list of order item sets. Each pair
  of products that appears together in an order increments their shared
  count symmetrically.
  """
  @spec build_matrix([order_items()]) :: co_occurrence_matrix()
  def build_matrix(orders) when is_list(orders) do
    Enum.reduce(orders, %{}, fn items, acc ->
      pairs = unique_pairs(items)
      Enum.reduce(pairs, acc, fn {a, b}, inner_acc ->
        inner_acc
        |> Map.update({a, b}, 1, &(&1 + 1))
        |> Map.update({b, a}, 1, &(&1 + 1))
      end)
    end)
  end

  @doc """
  Returns up to `limit` product recommendations for `product_id` given
  a pre-built co-occurrence matrix. Excludes products in `already_in_cart`.
  """
  @spec recommend(co_occurrence_matrix(), product_id(), [product_id()], pos_integer()) ::
          [recommendation()]
  def recommend(matrix, product_id, already_in_cart \\ [], limit \\ 5)
      when is_map(matrix) and is_binary(product_id) and is_list(already_in_cart) do
    exclude = MapSet.new([product_id | already_in_cart])

    matrix
    |> Enum.filter(fn {{a, _b}, _score} -> a == product_id end)
    |> Enum.map(fn {{_a, b}, score} -> %{product_id: b, score: score} end)
    |> Enum.reject(fn %{product_id: pid} -> MapSet.member?(exclude, pid) end)
    |> Enum.sort_by(& &1.score, :desc)
    |> Enum.take(limit)
  end

  @doc "Returns all products that co-occurred with `product_id` at least once."
  @spec related_products(co_occurrence_matrix(), product_id()) :: [product_id()]
  def related_products(matrix, product_id) when is_binary(product_id) do
    matrix
    |> Enum.filter(fn {{a, _b}, _} -> a == product_id end)
    |> Enum.map(fn {{_a, b}, _} -> b end)
    |> Enum.uniq()
  end

  @doc "Normalises a matrix so each score is divided by the row maximum."
  @spec normalise(co_occurrence_matrix()) :: %{{product_id(), product_id()} => float()}
  def normalise(matrix) when is_map(matrix) do
    max_by_product =
      Enum.reduce(matrix, %{}, fn {{a, _b}, score}, acc ->
        Map.update(acc, a, score, &max(&1, score))
      end)

    Map.new(matrix, fn {{a, b}, score} ->
      max_val = Map.get(max_by_product, a, 1)
      {{a, b}, if(max_val > 0, do: Float.round(score / max_val, 4), else: 0.0)}
    end)
  end

  defp unique_pairs(items) do
    sorted = Enum.sort(Enum.uniq(items))
    for a <- sorted, b <- sorted, a < b, do: {a, b}
  end
end
```
