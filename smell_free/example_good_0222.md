```elixir
defmodule MyApp.Recommendations.CollaborativeFilter do
  @moduledoc """
  Generates item recommendations using user-based collaborative filtering.
  Similarity between users is computed with the Jaccard coefficient over
  the sets of items each user has engaged with. Computations are entirely
  in-memory and stateless — results may be cached by the caller.

  Suitable for small-to-medium catalogues (up to ~50k user-item pairs).
  For larger datasets, delegate to an offline ML pipeline and cache results.
  """

  @type user_id :: String.t()
  @type item_id :: String.t()
  @type interaction_matrix :: %{user_id() => MapSet.t()}
  @type recommendation :: %{item_id: item_id(), score: float()}

  @doc """
  Returns up to `limit` item recommendations for `target_user` based on
  the engagement history in `matrix`. Items the user has already interacted
  with are excluded from the output.

  Returns an empty list if the user has no history or no neighbours exist.
  """
  @spec recommend(user_id(), interaction_matrix(), pos_integer()) :: [recommendation()]
  def recommend(target_user, matrix, limit \\ 10)
      when is_binary(target_user) and is_map(matrix) and is_integer(limit) and limit > 0 do
    target_items = Map.get(matrix, target_user, MapSet.new())

    if MapSet.size(target_items) == 0 do
      []
    else
      matrix
      |> compute_neighbour_scores(target_user, target_items)
      |> aggregate_candidate_scores(matrix, target_items)
      |> Enum.sort_by(& &1.score, :desc)
      |> Enum.take(limit)
    end
  end

  @doc """
  Computes the Jaccard similarity between two sets of item IDs.
  Returns a float in the range `[0.0, 1.0]`.
  """
  @spec jaccard(MapSet.t(), MapSet.t()) :: float()
  def jaccard(set_a, set_b) do
    intersection = MapSet.intersection(set_a, set_b) |> MapSet.size()
    union = MapSet.union(set_a, set_b) |> MapSet.size()

    if union == 0, do: 0.0, else: intersection / union
  end

  @spec compute_neighbour_scores(interaction_matrix(), user_id(), MapSet.t()) ::
          [{user_id(), float()}]
  defp compute_neighbour_scores(matrix, target_user, target_items) do
    matrix
    |> Enum.reject(fn {user, _} -> user == target_user end)
    |> Enum.map(fn {user, items} -> {user, jaccard(target_items, items)} end)
    |> Enum.reject(fn {_, score} -> score == 0.0 end)
    |> Enum.sort_by(&elem(&1, 1), :desc)
    |> Enum.take(50)
  end

  @spec aggregate_candidate_scores(
          [{user_id(), float()}],
          interaction_matrix(),
          MapSet.t()
        ) :: [recommendation()]
  defp aggregate_candidate_scores(neighbours, matrix, target_items) do
    neighbours
    |> Enum.flat_map(fn {user, sim} ->
      matrix
      |> Map.get(user, MapSet.new())
      |> MapSet.difference(target_items)
      |> Enum.map(fn item -> {item, sim} end)
    end)
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Enum.map(fn {item, scores} ->
      %{item_id: item, score: Enum.sum(scores) / length(scores)}
    end)
  end
end
```
