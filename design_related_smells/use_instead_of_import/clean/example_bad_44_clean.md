```elixir
defmodule StatUtils do
  def mean([]), do: 0.0
  def mean(list) do
    Enum.sum(list) / length(list)
  end

  def median([]), do: 0.0
  def median(list) do
    sorted = Enum.sort(list)
    n      = length(sorted)
    mid    = div(n, 2)
    if rem(n, 2) == 0 do
      (Enum.at(sorted, mid - 1) + Enum.at(sorted, mid)) / 2.0
    else
      Enum.at(sorted, mid) * 1.0
    end
  end

  def std_dev([]), do: 0.0
  def std_dev(list) do
    m = mean(list)
    variance = Enum.map(list, fn x -> :math.pow(x - m, 2) end) |> mean()
    :math.sqrt(variance)
  end
end

defmodule ReportHelpers do
  defmacro __using__(_opts) do
    quote do
      import StatUtils

      def group_by_period(records, :month) do
        Enum.group_by(records, fn r ->
          %{year: r.date.year, month: r.date.month}
        end)
      end

      def group_by_period(records, :quarter) do
        Enum.group_by(records, fn r ->
          %{year: r.date.year, quarter: ceil(r.date.month / 3)}
        end)
      end

      def sum_revenue(records) do
        Enum.sum(Enum.map(records, & &1.revenue))
      end

      def growth_rate(current, previous) when previous > 0 do
        Float.round((current - previous) / previous * 100.0, 2)
      end
      def growth_rate(_, _), do: nil
    end
  end
end

defmodule SalesReportBuilder do
  use ReportHelpers

  @top_n_default 10

  def build(records, opts \\ []) do
    period   = Keyword.get(opts, :period, :month)
    top_n    = Keyword.get(opts, :top, @top_n_default)
    grouped  = group_by_period(records, period)

    periods =
      grouped
      |> Enum.map(fn {period_key, recs} ->
        revenues = Enum.map(recs, & &1.revenue)
        %{
          period:     period_key,
          revenue:    sum_revenue(recs),
          avg_order:  mean(revenues),
          median_order: median(revenues),
          std_dev:    Float.round(std_dev(revenues), 2),
          count:      length(recs)
        }
      end)
      |> Enum.sort_by(& &1.revenue, :desc)

    %{
      generated_at:  DateTime.utc_now(),
      period_type:   period,
      periods:       periods,
      top_products:  top_products(records, top_n),
      by_region:     aggregate_by_region(records),
      overall_stats: overall_stats(records)
    }
  end

  def aggregate_by_region(records) do
    records
    |> Enum.group_by(& &1.region)
    |> Enum.map(fn {region, recs} ->
      revenues = Enum.map(recs, & &1.revenue)
      %{
        region:  region,
        revenue: sum_revenue(recs),
        avg:     mean(revenues),
        count:   length(recs)
      }
    end)
    |> Enum.sort_by(& &1.revenue, :desc)
  end

  def top_products(records, n \\ @top_n_default) do
    records
    |> Enum.group_by(& &1.product_id)
    |> Enum.map(fn {pid, recs} ->
      {pid, sum_revenue(recs)}
    end)
    |> Enum.sort_by(&elem(&1, 1), :desc)
    |> Enum.take(n)
  end

  defp overall_stats(records) do
    revenues = Enum.map(records, & &1.revenue)
    %{
      total:   Enum.sum(revenues),
      mean:    mean(revenues),
      median:  median(revenues),
      std_dev: Float.round(std_dev(revenues), 2),
      count:   length(revenues)
    }
  end
end
```
