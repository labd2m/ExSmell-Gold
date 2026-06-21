```elixir
defmodule Analytics.RetentionCohort do
  @moduledoc """
  Computes user retention cohorts from a flat list of activity events.
  Users are grouped into cohorts by their first-activity week. For each
  subsequent week the module tracks what percentage of each cohort returned.
  All computation is pure and operates on in-memory data structures.
  """

  @type user_id :: String.t()
  @type event :: %{user_id: user_id(), occurred_at: DateTime.t()}
  @type week_label :: String.t()
  @type cohort_row :: %{
          cohort_week: week_label(),
          cohort_size: pos_integer(),
          weeks: %{non_neg_integer() => float()}
        }

  @doc """
  Builds a retention cohort table from `events`. Each row represents a
  first-activity week cohort and its retention rates at weeks 0, 1, 2 etc.
  """
  @spec build([event()]) :: [cohort_row()]
  def build(events) when is_list(events) do
    first_seen = compute_first_seen(events)
    activity_by_user = group_activity_by_user(events)
    cohorts = group_users_into_cohorts(first_seen)

    cohorts
    |> Enum.map(fn {cohort_week, user_ids} ->
      retention = compute_retention(user_ids, cohort_week, activity_by_user)
      %{cohort_week: cohort_week, cohort_size: length(user_ids), weeks: retention}
    end)
    |> Enum.sort_by(& &1.cohort_week)
  end

  @doc "Returns the ISO week label for a given date or datetime."
  @spec week_label(Date.t() | DateTime.t()) :: week_label()
  def week_label(%DateTime{} = dt), do: dt |> DateTime.to_date() |> week_label()

  def week_label(%Date{} = date) do
    {year, week} = :calendar.iso_week_number(Date.to_erl(date))
    "#{year}-W#{week |> Integer.to_string() |> String.pad_leading(2, "0")}"
  end

  defp compute_first_seen(events) do
    Enum.reduce(events, %{}, fn %{user_id: uid, occurred_at: at}, acc ->
      Map.update(acc, uid, at, fn existing ->
        if DateTime.before?(at, existing), do: at, else: existing
      end)
    end)
  end

  defp group_activity_by_user(events) do
    Enum.group_by(events, & &1.user_id, fn e -> week_label(e.occurred_at) end)
    |> Map.new(fn {uid, weeks} -> {uid, MapSet.new(weeks)} end)
  end

  defp group_users_into_cohorts(first_seen) do
    Enum.group_by(first_seen, fn {_uid, dt} -> week_label(dt) end, fn {uid, _dt} -> uid end)
  end

  defp compute_retention(user_ids, cohort_week, activity_by_user) do
    cohort_size = length(user_ids)
    max_week_offset = 12

    Map.new(0..max_week_offset, fn offset ->
      target_week = week_offset(cohort_week, offset)
      retained = Enum.count(user_ids, fn uid ->
        uid |> then(&Map.get(activity_by_user, &1, MapSet.new())) |> MapSet.member?(target_week)
      end)
      rate = if cohort_size > 0, do: Float.round(retained / cohort_size * 100, 1), else: 0.0
      {offset, rate}
    end)
  end

  defp week_offset(week_label, offset) do
    [year_str, "W" <> week_str] = String.split(week_label, "-")
    {year, _} = Integer.parse(year_str)
    {week, _} = Integer.parse(week_str)
    total_weeks = (year - 1) * 52 + week + offset
    new_year = div(total_weeks - 1, 52) + 1
    new_week = rem(total_weeks - 1, 52) + 1
    "#{new_year}-W#{new_week |> Integer.to_string() |> String.pad_leading(2, "0")}"
  end
end
```
