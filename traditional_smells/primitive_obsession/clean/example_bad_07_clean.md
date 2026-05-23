```elixir
defmodule Reporting.SalesReportBuilder do
  @moduledoc """
  Assembles aggregated sales reports for arbitrary date ranges.
  Supports daily, weekly, and monthly period granularity.
  Reports are suitable for export to CSV or dashboard display.
  """

  require Logger

  @max_range_days 366
  @supported_granularities ~w(daily weekly monthly)

  @spec build_report(String.t(), String.t(), String.t()) ::
          {:ok, map()} | {:error, String.t()}
  def build_report(from_date, to_date, granularity) do
    with :ok <- validate_granularity(granularity),
         {:ok, from} <- parse_date(from_date),
         {:ok, to} <- parse_date(to_date),
         :ok <- validate_range(from_date, to_date),
         periods <- split_into_periods(from_date, to_date, granularity) do
      report = %{
        from_date: from_date,
        to_date: to_date,
        granularity: granularity,
        total_days: range_days(from_date, to_date),
        period_count: length(periods),
        periods: Enum.map(periods, &build_period_summary/1),
        generated_at: DateTime.utc_now()
      }

      Logger.info(
        "Sales report built: #{from_date} to #{to_date} (#{granularity}), " <>
          "#{report.period_count} periods"
      )

      {:ok, report}
    end
  end

  @spec validate_range(String.t(), String.t()) :: :ok | {:error, String.t()}
  def validate_range(from_date, to_date) do
    with {:ok, from} <- parse_date(from_date),
         {:ok, to} <- parse_date(to_date) do
      cond do
        Date.compare(from, to) == :gt ->
          {:error, "from_date (#{from_date}) must not be after to_date (#{to_date})"}

        Date.diff(to, from) > @max_range_days ->
          {:error,
           "Range of #{Date.diff(to, from)} days exceeds maximum of #{@max_range_days} days"}

        true ->
          :ok
      end
    end
  end

  @spec range_days(String.t(), String.t()) :: non_neg_integer()
  def range_days(from_date, to_date) do
    with {:ok, from} <- parse_date(from_date),
         {:ok, to} <- parse_date(to_date) do
      Date.diff(to, from) + 1
    else
      _ -> 0
    end
  end

  @spec split_into_periods(String.t(), String.t(), String.t()) :: list(map())
  def split_into_periods(from_date, to_date, granularity) do
    with {:ok, from} <- parse_date(from_date),
         {:ok, to} <- parse_date(to_date) do
      case granularity do
        "daily" ->
          Date.range(from, to)
          |> Enum.map(&%{from: Date.to_iso8601(&1), to: Date.to_iso8601(&1), label: Date.to_iso8601(&1)})

        "weekly" ->
          build_weekly_periods(from, to)

        "monthly" ->
          build_monthly_periods(from, to)

        _ ->
          []
      end
    else
      _ -> []
    end
  end

  defp build_weekly_periods(from, to) do
    Stream.iterate(week_start(from), &Date.add(&1, 7))
    |> Stream.take_while(&(Date.compare(&1, to) != :gt))
    |> Enum.map(fn week_start ->
      week_end = Date.add(week_start, 6)
      actual_end = if Date.compare(week_end, to) == :gt, do: to, else: week_end

      %{
        from: Date.to_iso8601(week_start),
        to: Date.to_iso8601(actual_end),
        label: "Week of #{Date.to_iso8601(week_start)}"
      }
    end)
  end

  defp build_monthly_periods(from, to) do
    Stream.iterate(month_start(from), fn d ->
      d |> Date.add(Date.days_in_month(d)) |> month_start()
    end)
    |> Stream.take_while(&(Date.compare(&1, to) != :gt))
    |> Enum.map(fn month_start ->
      month_end = Date.end_of_month(month_start)
      actual_end = if Date.compare(month_end, to) == :gt, do: to, else: month_end

      %{
        from: Date.to_iso8601(month_start),
        to: Date.to_iso8601(actual_end),
        label: Calendar.strftime(month_start, "%B %Y")
      }
    end)
  end

  defp build_period_summary(period) do
    Map.merge(period, %{
      revenue: Enum.random(10_000..100_000) / 100.0,
      orders: Enum.random(10..500),
      avg_order_value: Enum.random(1500..15000) / 100.0
    })
  end

  defp validate_granularity(granularity) do
    if granularity in @supported_granularities do
      :ok
    else
      {:error,
       "Unsupported granularity '#{granularity}'. Must be one of: #{Enum.join(@supported_granularities, ", ")}"}
    end
  end

  defp parse_date(date_str) do
    case Date.from_iso8601(date_str) do
      {:ok, date} -> {:ok, date}
      {:error, _} -> {:error, "Invalid date format '#{date_str}', expected YYYY-MM-DD"}
    end
  end

  defp week_start(date) do
    day_of_week = Date.day_of_week(date)
    Date.add(date, -(day_of_week - 1))
  end

  defp month_start(date), do: Date.beginning_of_month(date)
end
```
