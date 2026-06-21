```elixir
defmodule Recommendations.CollaborativeFilter do
  @moduledoc """
  Computes item recommendations using user-based collaborative filtering.
  Given a sparse user-item rating matrix, it finds the most similar users
  to a target user via cosine similarity and returns items rated highly
  by those neighbours but not yet seen by the target user. All computation
  is pure and operates on plain maps.
  """

  @type user_id :: String.t()
  @type item_id :: String.t()
  @type rating :: float()
  @type ratings_matrix :: %{user_id() => %{item_id() => rating()}}
  @type recommendation :: %{item_id: item_id(), score: float()}

  @doc """
  Returns up to `limit` item recommendations for `user_id` by finding
  `neighbour_count` similar users and scoring their unseen items.
  """
  @spec recommend(ratings_matrix(), user_id(), pos_integer(), pos_integer()) ::
          {:ok, [recommendation()]} | {:error, :user_not_found}
  def recommend(matrix, user_id, neighbour_count \ 5, limit \ 10)
      when is_map(matrix) and is_binary(user_id) do
    case Map.get(matrix, user_id) do
      nil ->
        {:error, :user_not_found}

      target_ratings ->
        neighbours = find_neighbours(matrix, user_id, target_ratings, neighbour_count)
        recs = score_unseen_items(neighbours, target_ratings, limit)
        {:ok, recs}
    end
  end

  @doc "Returns the cosine similarity between two rating vectors."
  @spec cosine_similarity(%{item_id() => rating()}, %{item_id() => rating()}) :: float()
  def cosine_similarity(ratings_a, ratings_b) when is_map(ratings_a) and is_map(ratings_b) do
    common_items = Map.keys(ratings_a) |> Enum.filter(&Map.has_key?(ratings_b, &1))

    if Enum.empty?(common_items) do
      0.0
    else
      dot = Enum.sum(Enum.map(common_items, fn i -> ratings_a[i] * ratings_b[i] end))
      mag_a = :math.sqrt(Enum.sum(Enum.map(Map.values(ratings_a), fn r -> r * r end)))
      mag_b = :math.sqrt(Enum.sum(Enum.map(Map.values(ratings_b), fn r -> r * r end)))
      if mag_a > 0 and mag_b > 0, do: dot / (mag_a * mag_b), else: 0.0
    end
  end

  defp find_neighbours(matrix, user_id, target_ratings, count) do
    matrix
    |> Enum.reject(fn {uid, _} -> uid == user_id end)
    |> Enum.map(fn {uid, ratings} ->
      {uid, ratings, cosine_similarity(target_ratings, ratings)}
    end)
    |> Enum.sort_by(fn {_uid, _ratings, sim} -> sim end, :desc)
    |> Enum.take(count)
  end

  defp score_unseen_items(neighbours, target_ratings, limit) do
    seen_items = MapSet.new(Map.keys(target_ratings))

    neighbours
    |> Enum.flat_map(fn {_uid, ratings, similarity} ->
      ratings
      |> Enum.reject(fn {item_id, _} -> MapSet.member?(seen_items, item_id) end)
      |> Enum.map(fn {item_id, rating} -> {item_id, rating * similarity} end)
    end)
    |> Enum.group_by(fn {item_id, _} -> item_id end)
    |> Enum.map(fn {item_id, scores} ->
      total = Enum.sum(Enum.map(scores, fn {_, s} -> s end))
      %{item_id: item_id, score: Float.round(total, 4)}
    end)
    |> Enum.sort_by(& &1.score, :desc)
    |> Enum.take(limit)
  end
end
```
