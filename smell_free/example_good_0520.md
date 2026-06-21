```elixir
defmodule MyApp.Feeds.RecommendationFeed do
  @moduledoc """
  Builds a personalised recommendation feed for a user by blending
  collaborative-filter suggestions with trending and editorial picks.
  Each source contributes a fixed fraction of the feed; sources that
  return fewer items than their quota are backfilled from the next
  highest-priority source.

  The blending logic is purely functional and separated from data
  fetching, making each layer independently testable.
  """

  alias MyApp.Recommendations.CollaborativeFilter
  alias MyApp.Analytics.TrendingItems
  alias MyApp.Editorial.CuratedPicks

  @type feed_item :: %{id: String.t(), type: atom(), source: atom(), score: float()}
  @type user_id :: String.t()

  @sources [
    {:collaborative, 0.50},
    {:trending, 0.30},
    {:editorial, 0.20}
  ]

  @doc """
  Returns a recommendation feed of `size` items for `user_id`, blending
  sources according to the configured allocation ratios.
  """
  @spec build(user_id(), pos_integer()) :: [feed_item()]
  def build(user_id, size \\ 20) when is_binary(user_id) and is_integer(size) and size > 0 do
    sourced = fetch_all_sources(user_id, size * 2)
    blend(sourced, size)
  end

  @spec fetch_all_sources(user_id(), pos_integer()) :: %{atom() => [feed_item()]}
  defp fetch_all_sources(user_id, pool_size) do
    tasks = %{
      collaborative: Task.async(fn -> fetch_collaborative(user_id, pool_size) end),
      trending: Task.async(fn -> fetch_trending(pool_size) end),
      editorial: Task.async(fn -> fetch_editorial(pool_size) end)
    }

    Map.new(tasks, fn {source, task} ->
      items =
        case Task.yield(task, 3_000) || Task.shutdown(task, :brutal_kill) do
          {:ok, result} -> result
          _ -> []
        end

      {source, items}
    end)
  end

  @spec blend(%{atom() => [feed_item()]}, pos_integer()) :: [feed_item()]
  defp blend(sourced, size) do
    quotas = Enum.map(@sources, fn {source, ratio} -> {source, round(size * ratio)} end)
    {allocated, _} = Enum.map_reduce(quotas, sourced, &allocate_quota/2)
    backfill(List.flatten(allocated), sourced, size)
  end

  @spec allocate_quota({atom(), pos_integer()}, %{atom() => [feed_item()]}) ::
          {[feed_item()], %{atom() => [feed_item()]}}
  defp allocate_quota({source, quota}, remaining) do
    available = Map.get(remaining, source, [])
    taken = Enum.take(available, quota)
    rest = Map.put(remaining, source, Enum.drop(available, quota))
    {taken, rest}
  end

  @spec backfill([feed_item()], %{atom() => [feed_item()]}, pos_integer()) :: [feed_item()]
  defp backfill(current, sourced, size) when length(current) >= size do
    Enum.take(current, size)
  end

  defp backfill(current, sourced, size) do
    needed = size - length(current)
    existing_ids = MapSet.new(current, & &1.id)

    extras =
      sourced
      |> Map.values()
      |> List.flatten()
      |> Enum.reject(fn item -> MapSet.member?(existing_ids, item.id) end)
      |> Enum.take(needed)

    Enum.take(current ++ extras, size)
  end

  @spec fetch_collaborative(user_id(), pos_integer()) :: [feed_item()]
  defp fetch_collaborative(user_id, limit) do
    matrix = CollaborativeFilter.user_matrix(user_id)

    CollaborativeFilter.recommend(user_id, matrix, limit)
    |> Enum.map(&to_feed_item(&1.item_id, :product, :collaborative, &1.score))
  end

  @spec fetch_trending(pos_integer()) :: [feed_item()]
  defp fetch_trending(limit) do
    TrendingItems.top(limit)
    |> Enum.with_index(1)
    |> Enum.map(fn {item, rank} ->
      to_feed_item(item.id, :product, :trending, 1.0 / rank)
    end)
  end

  @spec fetch_editorial(pos_integer()) :: [feed_item()]
  defp fetch_editorial(limit) do
    CuratedPicks.current(limit)
    |> Enum.map(fn item -> to_feed_item(item.id, :product, :editorial, 1.0) end)
  end

  @spec to_feed_item(String.t(), atom(), atom(), float()) :: feed_item()
  defp to_feed_item(id, type, source, score) do
    %{id: id, type: type, source: source, score: score}
  end
end
```
