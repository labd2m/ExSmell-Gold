# Code Smell: "Use" instead of "import"

## Metadata

- **Smell name:** "Use" instead of "import"
- **Expected smell location:** `SalesReportBuilder` module, top-level directive
- **Affected function(s):** `build/2`, `aggregate_by_region/1`, `top_products/2`
- **Short explanation:** `SalesReportBuilder` calls `use ReportHelpers` to gain aggregation utilities. The `__using__/1` macro silently injects an `import` of `StatUtils` into `SalesReportBuilder`, making statistical functions available without any visible declaration. Replacing `use ReportHelpers` with `import ReportHelpers` (and adding an explicit `import StatUtils` where needed) would eliminate the hidden dependency and make the module's imports self-documenting.

---

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
      # VALIDATION: SMELL START - "Use" instead of "import"
      # VALIDATION: This is a smell because __using__/1 injects `import StatUtils`
      # VALIDATION: into SalesReportBuilder. The functions mean/1, median/1, and std_dev/1
      # VALIDATION: appear in SalesReportBuilder without any explicit indication of their
      # VALIDATION: origin. Readers must inspect ReportHelpers to understand the full
      # VALIDATION: dependency surface. A plain `import ReportHelpers` at the call site
      # VALIDATION: would prevent this hidden propagation.
      import StatUtils
      # VALIDATION: SMELL END

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
