```elixir
defmodule Analytics.Cohorts.RetentionCalculator do
  @moduledoc """
  Computes user retention cohort tables from activity event streams.

  Groups users by acquisition period and tracks their activity presence
  across subsequent time intervals to produce standard cohort retention matrices.
  """

  alias Analytics.Cohorts.{EventStream, CohortGroup, RetentionMatrix}

  @type interval :: :day | :week | :month
  @type cohort_key :: Date.t()
  @type retention_rate :: float()

  @type retention_result :: %{
          cohort_date: cohort_key(),
          cohort_size: pos_integer(),
          intervals: [%{period: non_neg_integer(), rate: retention_rate(), active_users: non_neg_integer()}]
        }

  @doc """
  Computes the full retention matrix for user cohorts over a date range.

  Groups users by their first activity date (acquisition date) and measures
  return activity at each subsequent interval.
  """
  @spec compute(EventStream.t(), Date.t(), Date.t(), interval(), pos_integer()) ::
          {:ok, RetentionMatrix.t()} | {:error, :invalid_date_range}
  def compute(%EventStream{} = stream, from_date, to_date, interval, max_periods)
      when max_periods > 0 do
    if Date.compare(from_date, to_date) in [:lt, :eq] do
      events = EventStream.load_range(stream, from_date, to_date)
      cohorts = build_cohort_groups(events, interval)
      rows = Enum.map(cohorts, &calculate_cohort_row(&1, events, interval, max_periods))
      {:ok, RetentionMatrix.new(rows, interval)}
    else
      {:error, :invalid_date_range}
    end
  end

  @doc """
  Computes the single-cohort retention row for a given acquisition date.
  """
  @spec cohort_row(EventStream.t(), Date.t(), interval(), pos_integer()) ::
          {:ok, retention_result()} | {:error, :no_users_in_cohort}
  def cohort_row(%EventStream{} = stream, cohort_date, interval, max_periods) do
    end_date = Date.add(cohort_date, interval_days(interval) * max_periods)
    events = EventStream.load_range(stream, cohort_date, end_date)

    cohort_users = users_acquired_on(events, cohort_date, interval)

    if Enum.empty?(cohort_users) do
      {:error, :no_users_in_cohort}
    else
      group = %CohortGroup{date: cohort_date, user_ids: cohort_users}
      row = calculate_cohort_row(group, events, interval, max_periods)
      {:ok, row}
    end
  end

  defp build_cohort_groups(events, interval) do
    events
    |> Enum.group_by(fn event -> truncate_to_interval(event.first_seen_date, interval) end)
    |> Enum.map(fn {date, period_events} ->
      user_ids = period_events |> Enum.map(& &1.user_id) |> Enum.uniq()
      %CohortGroup{date: date, user_ids: user_ids}
    end)
    |> Enum.sort_by(& &1.date, Date)
  end

  defp calculate_cohort_row(%CohortGroup{date: cohort_date, user_ids: user_ids}, events, interval, max_periods) do
    cohort_size = length(user_ids)
    user_id_set = MapSet.new(user_ids)

    intervals =
      for period <- 0..max_periods do
        period_start = Date.add(cohort_date, interval_days(interval) * period)
        period_end = Date.add(period_start, interval_days(interval) - 1)

        active = count_active_users(events, user_id_set, period_start, period_end)
        rate = if cohort_size > 0, do: Float.round(active / cohort_size * 100, 2), else: 0.0

        %{period: period, rate: rate, active_users: active}
      end

    %{cohort_date: cohort_date, cohort_size: cohort_size, intervals: intervals}
  end

  defp count_active_users(events, user_id_set, period_start, period_end) do
    events
    |> Enum.filter(fn event ->
      MapSet.member?(user_id_set, event.user_id) and
        Date.compare(event.activity_date, period_start) in [:gt, :eq] and
        Date.compare(event.activity_date, period_end) in [:lt, :eq]
    end)
    |> Enum.map(& &1.user_id)
    |> Enum.uniq()
    |> length()
  end

  defp users_acquired_on(events, cohort_date, interval) do
    period_end = Date.add(cohort_date, interval_days(interval) - 1)

    events
    |> Enum.filter(fn event ->
      Date.compare(event.first_seen_date, cohort_date) in [:gt, :eq] and
        Date.compare(event.first_seen_date, period_end) in [:lt, :eq]
    end)
    |> Enum.map(& &1.user_id)
    |> Enum.uniq()
  end

  defp truncate_to_interval(date, :day), do: date
  defp truncate_to_interval(date, :week), do: Date.beginning_of_week(date)
  defp truncate_to_interval(date, :month), do: Date.beginning_of_month(date)

  defp interval_days(:day), do: 1
  defp interval_days(:week), do: 7
  defp interval_days(:month), do: 30
end
```
