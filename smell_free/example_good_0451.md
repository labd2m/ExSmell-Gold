```elixir
defmodule MyApp.Reporting.CohortAnalyser do
  @moduledoc """
  Performs cohort retention analysis over user signup and activity data.
  Users are grouped into weekly cohorts by their signup date; for each
  cohort the analyser computes the percentage who were active during each
  subsequent week. The result is a retention matrix suitable for rendering
  as a heatmap in a product analytics dashboard.

  All computation is purely functional and operates on pre-fetched data
  to keep database concerns out of the analysis logic.
  """

  @type user_id :: String.t()
  @type cohort_week :: Date.t()

  @type user_record :: %{
          required(:user_id) => user_id(),
          required(:signed_up_on) => Date.t(),
          required(:active_weeks) => [Date.t()]
        }

  @type cohort_row :: %{
          cohort_week: cohort_week(),
          cohort_size: pos_integer(),
          retention: [%{week_offset: non_neg_integer(), active: non_neg_integer(), rate: float()}]
        }

  @doc """
  Builds a cohort retention matrix from `user_records`.
  Each row represents one signup cohort; retention is tracked for up to
  `max_weeks` subsequent weeks.
  """
  @spec analyse([user_record()], pos_integer()) :: [cohort_row()]
  def analyse(user_records, max_weeks \\ 12)
      when is_list(user_records) and is_integer(max_weeks) and max_weeks > 0 do
    user_records
    |> Enum.group_by(&week_start(&1.signed_up_on))
    |> Enum.map(fn {cohort_week, members} ->
      build_cohort_row(cohort_week, members, max_weeks)
    end)
    |> Enum.sort_by(& &1.cohort_week, Date)
  end

  @doc "Returns the average week-0 retention rate across all cohorts."
  @spec average_retention_week0([cohort_row()]) :: float()
  def average_retention_week0([]), do: 0.0

  def average_retention_week0(rows) do
    rates =
      rows
      |> Enum.flat_map(fn row ->
        row.retention
        |> Enum.filter(&(&1.week_offset == 0))
        |> Enum.map(& &1.rate)
      end)

    if rates == [], do: 0.0, else: Enum.sum(rates) / length(rates)
  end

  @spec build_cohort_row(cohort_week(), [user_record()], pos_integer()) :: cohort_row()
  defp build_cohort_row(cohort_week, members, max_weeks) do
    cohort_size = length(members)

    retention =
      0..(max_weeks - 1)
      |> Enum.map(fn offset ->
        target_week = Date.add(cohort_week, offset * 7)
        active = Enum.count(members, &was_active_on(&1, target_week))
        rate = if cohort_size > 0, do: Float.round(active / cohort_size * 100, 1), else: 0.0
        %{week_offset: offset, active: active, rate: rate}
      end)

    %{cohort_week: cohort_week, cohort_size: cohort_size, retention: retention}
  end

  @spec was_active_on(user_record(), Date.t()) :: boolean()
  defp was_active_on(user, target_week) do
    Enum.any?(user.active_weeks, fn w -> Date.diff(w, target_week) in 0..6 end)
  end

  @spec week_start(Date.t()) :: Date.t()
  defp week_start(date) do
    day_of_week = Date.day_of_week(date)
    Date.add(date, -(day_of_week - 1))
  end
end
```
