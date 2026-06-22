```elixir
defmodule Recommendations.CollaborativeFilter do
  @moduledoc """
  Item-based collaborative filtering engine for generating product recommendations.
  Computes item similarity from a sparse user-item interaction matrix and returns
  ranked candidate items for a given user's interaction history.
  """

  @type item_id :: String.t()
  @type user_id :: String.t()
  @type interaction_matrix :: %{user_id() => MapSet.t(item_id())}
  @type similarity_score :: float()

  @spec recommendations_for(user_id(), interaction_matrix(), pos_integer()) ::
          {:ok, [item_id()]} | {:error, :no_history}
  def recommendations_for(user_id, matrix, limit)
      when is_binary(user_id) and is_map(matrix) and is_integer(limit) and limit > 0 do
    case Map.get(matrix, user_id) do
      nil -> {:error, :no_history}
      items when map_size(items) == 0 -> {:error, :no_history}
      user_items ->
        candidates = find_candidates(user_items, matrix, user_id)
        scored = score_candidates(candidates, user_items, matrix)
        ranked = ranked_items(scored, user_items, limit)
        {:ok, ranked}
    end
  end

  @spec item_similarity(item_id(), item_id(), interaction_matrix()) :: similarity_score()
  def item_similarity(item_a, item_b, matrix) when is_binary(item_a) and is_binary(item_b) do
    users_a = users_who_interacted(item_a, matrix)
    users_b = users_who_interacted(item_b, matrix)
    jaccard_similarity(users_a, users_b)
  end

  @spec find_candidates(MapSet.t(item_id()), interaction_matrix(), user_id()) :: MapSet.t(item_id())
  defp find_candidates(user_items, matrix, user_id) do
    matrix
    |> Enum.reject(fn {uid, _} -> uid == user_id end)
    |> Enum.flat_map(fn {_, items} -> MapSet.to_list(items) end)
    |> MapSet.new()
    |> MapSet.difference(user_items)
  end

  @spec score_candidates(MapSet.t(item_id()), MapSet.t(item_id()), interaction_matrix()) ::
          [{item_id(), similarity_score()}]
  defp score_candidates(candidates, user_items, matrix) do
    Enum.map(candidates, fn candidate ->
      score =
        user_items
        |> Enum.map(&item_similarity(&1, candidate, matrix))
        |> average_score()

      {candidate, score}
    end)
  end

  @spec ranked_items([{item_id(), similarity_score()}], MapSet.t(item_id()), pos_integer()) :: [item_id()]
  defp ranked_items(scored, _user_items, limit) do
    scored
    |> Enum.sort_by(fn {_, score} -> score end, :desc)
    |> Enum.take(limit)
    |> Enum.map(fn {item, _} -> item end)
  end

  @spec users_who_interacted(item_id(), interaction_matrix()) :: MapSet.t(user_id())
  defp users_who_interacted(item_id, matrix) do
    matrix
    |> Enum.filter(fn {_, items} -> MapSet.member?(items, item_id) end)
    |> MapSet.new(fn {user_id, _} -> user_id end)
  end

  @spec jaccard_similarity(MapSet.t(), MapSet.t()) :: similarity_score()
  defp jaccard_similarity(set_a, set_b) do
    intersection = MapSet.intersection(set_a, set_b) |> MapSet.size()
    union = MapSet.union(set_a, set_b) |> MapSet.size()

    if union == 0, do: 0.0, else: intersection / union
  end

  @spec average_score([similarity_score()]) :: similarity_score()
  defp average_score([]), do: 0.0
  defp average_score(scores), do: Enum.sum(scores) / length(scores)
end
```
