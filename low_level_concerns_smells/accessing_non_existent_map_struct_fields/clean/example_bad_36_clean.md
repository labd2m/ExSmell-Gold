```elixir
defmodule Reporting.SalesAggregator do
  @moduledoc """
  Builds period-over-period sales reports with optional segmentation
  by region, sales representative, and refund inclusion.
  Supports daily, weekly, and monthly granularity.
  """

  require Logger

  @granularities [:daily, :weekly, :monthly]

  @type sale :: %{
          id: String.t(),
          amount: float(),
          region: String.t(),
          rep_id: String.t(),
          is_refund: boolean(),
          closed_at: Date.t()
        }

  @type report_spec :: %{
          period_start: Date.t(),
          period_end: Date.t(),
          granularity: :daily | :weekly | :monthly,
          optional(:region_filter) => String.t(),
          optional(:rep_id) => String.t(),
          optional(:include_refunds) => boolean()
        }

  @spec build_report([sale()], report_spec()) ::
          {:ok, map()} | {:error, String.t()}
  def build_report(sales, spec) do
    with :ok <- validate_spec(spec) do
      filtered  = filter_sales(sales, spec)
      grouped   = group_by_period(filtered, spec.granularity)
      summary   = compute_summary(filtered)
      breakdown = build_breakdown(grouped)

      report = %{
        generated_at: DateTime.utc_now(),
        period:       %{from: spec.period_start, to: spec.period_end},
        granularity:  spec.granularity,
        summary:      summary,
        breakdown:    breakdown
      }

      Logger.info("Report built: #{length(filtered)} sales over #{map_size(grouped)} periods")
      {:ok, report}
    end
  end

  defp validate_spec(spec) do
    cond do
      spec.granularity not in @granularities ->
        {:error, "invalid granularity: #{spec.granularity}"}

      Date.compare(spec.period_start, spec.period_end) == :gt ->
        {:error, "period_start must be before period_end"}

      true ->
        :ok
    end
  end

  defp filter_sales(sales, spec) do
    region_filter   = spec[:region_filter]
    rep_id          = spec[:rep_id]
    include_refunds = spec[:include_refunds]

    sales
    |> Enum.filter(fn sale ->
      in_period?(sale.closed_at, spec.period_start, spec.period_end)
    end)
    |> then(fn s -> if region_filter, do: Enum.filter(s, &(&1.region == region_filter)), else: s end)
    |> then(fn s -> if rep_id,        do: Enum.filter(s, &(&1.rep_id == rep_id)),         else: s end)
    |> then(fn s -> if include_refunds, do: s, else: Enum.reject(s, & &1.is_refund)       end)
  end

  defp in_period?(date, from, to) do
    Date.compare(date, from) in [:gt, :eq] and Date.compare(date, to) in [:lt, :eq]
  end

  defp group_by_period(sales, :daily) do
    Enum.group_by(sales, & &1.closed_at)
  end

  defp group_by_period(sales, :weekly) do
    Enum.group_by(sales, fn sale ->
      {year, week} = :calendar.iso_week_number(Date.to_erl(sale.closed_at))
      "#{year}-W#{String.pad_leading(Integer.to_string(week), 2, "0")}"
    end)
  end

  defp group_by_period(sales, :monthly) do
    Enum.group_by(sales, fn sale ->
      "#{sale.closed_at.year}-#{String.pad_leading(Integer.to_string(sale.closed_at.month), 2, "0")}"
    end)
  end

  defp compute_summary(sales) do
    total    = Enum.reduce(sales, 0.0, &(&1.amount + &2))
    refunds  = sales |> Enum.filter(& &1.is_refund) |> Enum.reduce(0.0, &(&1.amount + &2))
    net      = total - refunds
    count    = length(sales)
    average  = if count > 0, do: Float.round(net / count, 2), else: 0.0

    %{total: Float.round(total, 2), refunds: Float.round(refunds, 2),
      net: Float.round(net, 2), count: count, average: average}
  end

  defp build_breakdown(grouped) do
    Enum.map(grouped, fn {period, sales} ->
      total = Enum.reduce(sales, 0.0, &(&1.amount + &2))
      %{period: period, count: length(sales), total: Float.round(total, 2)}
    end)
    |> Enum.sort_by(& &1.period)
  end
end
```
