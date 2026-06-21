# File: `example_good_418.md`

```elixir
defmodule Analytics.RetentionCohort do
  @moduledoc """
  Computes cohort retention tables from a set of dated user activity events.

  Users are grouped into cohorts by their first-seen date, truncated to
  a configurable period (week or month). Retention is then measured as
  the percentage of each cohort that returned in each subsequent period.

  All computation is pure; the caller supplies pre-fetched activity records.
  """

  @type user_id :: String.t()
  @type period_key :: Date.t()
  @type granularity :: :week | :month

  @type activity :: %{
          required(:user_id) => user_id(),
          required(:occurred_on) => Date.t()
        }

  @type period_result :: %{offset: non_neg_integer(), retained: non_neg_integer(), rate: float()}

  @type cohort_row :: %{
          cohort: period_key(),
          cohort_size: pos_integer(),
          periods: [period_result()]
        }

  @type retention_table :: %{
          granularity: granularity(),
          max_periods: pos_integer(),
          cohorts: [cohort_row()]
        }

  @doc """
  Builds a cohort retention table from `activities`.

  `granularity` controls cohort bucketing (`:week` or `:month`).
  `max_periods` caps how many follow-on periods are tracked per cohort.

  Returns a `retention_table` with rows sorted by cohort date ascending.
  """
  @spec build([activity()], granularity(), pos_integer()) :: retention_table()
  def build(activities, granularity \\ :week, max_periods \\ 8)
      when is_list(activities) and granularity in [:week, :month] and
             is_integer(max_periods) and max_periods > 0 do
    first_seen = compute_first_seen(activities)
    activity_by_user = group_activity_by_user(activities)

    cohorts =
      first_seen
      |> Enum.group_by(fn {_uid, date} -> truncate_to_period(date, granularity) end)
      |> Enum.map(fn {cohort_key, members} ->
        build_cohort_row(cohort_key, members, activity_by_user, granularity, max_periods)
      end)
      |> Enum.sort_by(& &1.cohort, Date)

    %{granularity: granularity, max_periods: max_periods, cohorts: cohorts}
  end

  @doc """
  Returns the retention rate for a specific cohort at a given period offset.

  Returns `{:ok, rate}` or `{:error, :not_found}`.
  """
  @spec rate_at(retention_table(), period_key(), non_neg_integer()) ::
          {:ok, float()} | {:error, :not_found}
  def rate_at(%{cohorts: cohorts}, cohort_key, offset) do
    with {:ok, row} <- find_cohort(cohorts, cohort_key),
         {:ok, period} <- find_period(row.periods, offset) do
      {:ok, period.rate}
    end
  end

  defp compute_first_seen(activities) do
    Enum.reduce(activities, %{}, fn %{user_id: uid, occurred_on: date}, acc ->
      Map.update(acc, uid, date, fn existing ->
        if Date.compare(date, existing) == :lt, do: date, else: existing
      end)
    end)
  end

  defp group_activity_by_user(activities) do
    Enum.reduce(activities, %{}, fn %{user_id: uid, occurred_on: date}, acc ->
      Map.update(acc, uid, MapSet.new([date]), &MapSet.put(&1, date))
    end)
  end

  defp build_cohort_row(cohort_key, members, activity_by_user, granularity, max_periods) do
    cohort_uids = Enum.map(members, &elem(&1, 0))
    cohort_size = length(cohort_uids)

    periods =
      Enum.map(0..max_periods, fn offset ->
        period_start = advance_period(cohort_key, granularity, offset)

        retained =
          Enum.count(cohort_uids, fn uid ->
            activity_by_user
            |> Map.get(uid, MapSet.new())
            |> Enum.any?(fn d -> truncate_to_period(d, granularity) == period_start end)
          end)

        rate = if cohort_size > 0, do: Float.round(retained / cohort_size * 100.0, 1), else: 0.0
        %{offset: offset, retained: retained, rate: rate}
      end)

    %{cohort: cohort_key, cohort_size: cohort_size, periods: periods}
  end

  defp truncate_to_period(date, :week) do
    Date.add(date, -(Date.day_of_week(date) - 1))
  end

  defp truncate_to_period(date, :month), do: %{date | day: 1}

  defp advance_period(date, :week, n), do: Date.add(date, n * 7)
  defp advance_period(date, :month, n), do: Date.add(date, n * 30)

  defp find_cohort(cohorts, key) do
    case Enum.find(cohorts, &(&1.cohort == key)) do
      nil -> {:error, :not_found}
      row -> {:ok, row}
    end
  end

  defp find_period(periods, offset) do
    case Enum.find(periods, &(&1.offset == offset)) do
      nil -> {:error, :not_found}
      period -> {:ok, period}
    end
  end
end
```
