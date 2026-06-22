```elixir
defmodule MyApp.Analytics.RetentionCurve do
  @moduledoc """
  Computes user retention curves from raw login event data. A retention
  curve describes what percentage of users who first appeared in a given
  cohort week were still active N weeks later. The calculation is purely
  functional and operates on pre-fetched data structures to keep this
  module free of database dependencies.
  """

  @type user_id :: String.t()
  @type week :: Date.t()

  @type event :: %{
          required(:user_id) => user_id(),
          required(:occurred_on) => Date.t()
        }

  @type curve_point :: %{
          week_offset: non_neg_integer(),
          retained: non_neg_integer(),
          rate: float()
        }

  @type cohort_curve :: %{
          cohort_week: week(),
          cohort_size: pos_integer(),
          points: [curve_point()]
        }

  @doc """
  Computes retention curves for each signup cohort in `events`. Users
  are grouped by the week of their first event. Activity in subsequent
  weeks is measured against the cohort. Returns one `cohort_curve` per
  signup week, ordered chronologically.
  """
  @spec compute([event()], pos_integer()) :: [cohort_curve()]
  def compute(events, max_weeks \\ 12)
      when is_list(events) and is_integer(max_weeks) and max_weeks > 0 do
    user_first_seen = first_seen_week(events)
    user_active_weeks = active_weeks_per_user(events)

    user_first_seen
    |> Enum.group_by(fn {_uid, week} -> week end, fn {uid, _week} -> uid end)
    |> Enum.map(fn {cohort_week, user_ids} ->
      points = retention_points(user_ids, cohort_week, user_active_weeks, max_weeks)
      %{cohort_week: cohort_week, cohort_size: length(user_ids), points: points}
    end)
    |> Enum.sort_by(& &1.cohort_week, Date)
  end

  @doc "Returns the week-0 retention rate for a given cohort curve."
  @spec week0_rate(cohort_curve()) :: float()
  def week0_rate(%{points: [first | _]}), do: first.rate
  def week0_rate(_), do: 0.0

  @doc """
  Returns the average retention rate at `week_offset` across all
  cohort curves, weighted by cohort size.
  """
  @spec weighted_average([cohort_curve()], non_neg_integer()) :: float()
  def weighted_average(curves, week_offset) do
    relevant =
      curves
      |> Enum.flat_map(fn c ->
        case Enum.find(c.points, &(&1.week_offset == week_offset)) do
          nil -> []
          pt -> [{pt.rate, c.cohort_size}]
        end
      end)

    total_users = Enum.sum_by(relevant, &elem(&1, 1))

    if total_users == 0 do
      0.0
    else
      Enum.sum_by(relevant, fn {rate, size} -> rate * size end) / total_users
      |> Float.round(4)
    end
  end

  @spec first_seen_week([event()]) :: %{user_id() => week()}
  defp first_seen_week(events) do
    events
    |> Enum.group_by(& &1.user_id)
    |> Map.new(fn {uid, evts} ->
      earliest = evts |> Enum.map(& &1.occurred_on) |> Enum.min(Date)
      {uid, week_start(earliest)}
    end)
  end

  @spec active_weeks_per_user([event()]) :: %{user_id() => MapSet.t()}
  defp active_weeks_per_user(events) do
    Enum.reduce(events, %{}, fn event, acc ->
      week = week_start(event.occurred_on)
      Map.update(acc, event.user_id, MapSet.new([week]), &MapSet.put(&1, week))
    end)
  end

  @spec retention_points([user_id()], week(), %{user_id() => MapSet.t()}, pos_integer()) ::
          [curve_point()]
  defp retention_points(user_ids, cohort_week, active_weeks, max_weeks) do
    cohort_size = length(user_ids)

    0..(max_weeks - 1)
    |> Enum.map(fn offset ->
      target = Date.add(cohort_week, offset * 7)

      retained =
        Enum.count(user_ids, fn uid ->
          uid
          |> then(&Map.get(active_weeks, &1, MapSet.new()))
          |> Enum.any?(fn w -> Date.diff(w, target) in 0..6 end)
        end)

      rate = if cohort_size > 0, do: Float.round(retained / cohort_size * 100, 2), else: 0.0
      %{week_offset: offset, retained: retained, rate: rate}
    end)
  end

  @spec week_start(Date.t()) :: week()
  defp week_start(date) do
    days_since_monday = Date.day_of_week(date) - 1
    Date.add(date, -days_since_monday)
  end
end
```
