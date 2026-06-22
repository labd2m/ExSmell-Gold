```elixir
defmodule Realtime.PresenceSummary do
  @moduledoc """
  Aggregates Phoenix Presence data into lightweight summary statistics
  for dashboard display. Computes unique user counts, page-level breakdowns,
  and join/leave rates over a sliding window. All computation is pure
  and operates on the Presence map returned by `Phoenix.Presence.list/2`.
  """

  @type user_id :: String.t()
  @type page :: String.t()
  @type presence_entry :: %{metas: [map()]}
  @type presence_map :: %{user_id() => presence_entry()}
  @type page_count :: %{page() => non_neg_integer()}
  @type summary :: %{
          online_count: non_neg_integer(),
          anonymous_count: non_neg_integer(),
          authenticated_count: non_neg_integer(),
          by_page: page_count(),
          multi_tab_users: non_neg_integer()
        }

  @doc "Computes a summary from a Phoenix Presence list map."
  @spec summarise(presence_map()) :: summary()
  def summarise(presence_map) when is_map(presence_map) do
    entries = Map.values(presence_map)
    all_metas = Enum.flat_map(entries, & &1.metas)
    total = length(entries)

    authenticated = Enum.count(all_metas, fn m -> Map.get(m, :user_id) != nil end)
    multi_tab = Enum.count(entries, fn e -> length(e.metas) > 1 end)
    by_page = count_by_page(all_metas)

    %{
      online_count: total,
      anonymous_count: total - authenticated,
      authenticated_count: authenticated,
      by_page: by_page,
      multi_tab_users: multi_tab
    }
  end

  @doc "Returns the top `n` most visited pages sorted by presence count descending."
  @spec top_pages(presence_map(), pos_integer()) :: [{page(), non_neg_integer()}]
  def top_pages(presence_map, n \ 5) when is_map(presence_map) and is_integer(n) and n > 0 do
    presence_map
    |> Map.values()
    |> Enum.flat_map(& &1.metas)
    |> count_by_page()
    |> Enum.sort_by(fn {_page, count} -> count end, :desc)
    |> Enum.take(n)
  end

  @doc """
  Computes the join and leave counts by diffing two consecutive presence maps.
  Returns the count of new arrivals and departures.
  """
  @spec diff(presence_map(), presence_map()) :: %{joins: non_neg_integer(), leaves: non_neg_integer()}
  def diff(prev_map, curr_map) when is_map(prev_map) and is_map(curr_map) do
    prev_ids = MapSet.new(Map.keys(prev_map))
    curr_ids = MapSet.new(Map.keys(curr_map))

    joins = MapSet.difference(curr_ids, prev_ids) |> MapSet.size()
    leaves = MapSet.difference(prev_ids, curr_ids) |> MapSet.size()

    %{joins: joins, leaves: leaves}
  end

  @doc "Returns true when the given `user_id` is present in the map."
  @spec online?(presence_map(), user_id()) :: boolean()
  def online?(presence_map, user_id) when is_binary(user_id) do
    Map.has_key?(presence_map, user_id)
  end

  @doc "Returns the number of open tabs for `user_id`, or 0 if not present."
  @spec tab_count(presence_map(), user_id()) :: non_neg_integer()
  def tab_count(presence_map, user_id) when is_binary(user_id) do
    case Map.get(presence_map, user_id) do
      nil -> 0
      entry -> length(entry.metas)
    end
  end

  defp count_by_page(metas) do
    Enum.reduce(metas, %{}, fn meta, acc ->
      page = Map.get(meta, :page, "unknown")
      Map.update(acc, page, 1, &(&1 + 1))
    end)
  end
end
```
