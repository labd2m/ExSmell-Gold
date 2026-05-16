# Code Smell: Working with invalid data

- **Smell name:** Working with invalid data
- **Expected smell location:** `build_report/2`, where `period_days` is read from an external map and forwarded to `DateRangeBuilder.compute/2` without validation
- **Affected function(s):** `build_report/2`, `resolve_date_range/1`
- **Short explanation:** `period_days` is extracted from a caller-supplied configuration map using `Map.get/3` and immediately passed to `DateRangeBuilder.compute/2`. No check is performed to confirm the value is an integer or positive. If a string, float, or nil slips in, the error will originate inside `DateRangeBuilder` or `Date.add/2`, far from the public entry point, with no message pointing to the unvalidated `period_days` parameter.

```elixir
defmodule Reporting.SalesReportBuilder do
  @moduledoc """
  Generates periodic sales reports by aggregating order data,
  computing KPIs, and exporting results to the reporting warehouse.
  """

  alias Reporting.DateRangeBuilder
  alias Reporting.OrderAggregator
  alias Reporting.KpiCalculator
  alias Reporting.WarehouseExporter

  @supported_groupings [:daily, :weekly, :monthly]
  @default_grouping :daily
  @default_currency "BRL"

  def build_report(report_config, requester_id) do
    with {:ok, date_range} <- resolve_date_range(report_config),
         {:ok, grouping} <- resolve_grouping(report_config),
         {:ok, raw_data} <- OrderAggregator.fetch(date_range, grouping),
         {:ok, kpis} <- KpiCalculator.compute(raw_data, date_range),
         {:ok, export_ref} <- WarehouseExporter.export(kpis, requester_id, date_range) do
      {:ok,
       %{
         export_ref: export_ref,
         period: date_range,
         grouping: grouping,
         kpi_summary: summarize_kpis(kpis)
       }}
    end
  end

  # VALIDATION: SMELL START - Working with invalid data
  # VALIDATION: This is a smell because `period_days` is taken directly from
  # the external `report_config` map with no type or range validation.
  # The raw value is immediately forwarded to `DateRangeBuilder.compute/2`,
  # which internally calls `Date.add/2`. If the caller provides a binary
  # like "30", a float like 30.5, or nil, the error will emerge deep inside
  # `DateRangeBuilder` or `Date.add/2` with no reference to `period_days`
  # or the reporting boundary, making the root cause very hard to diagnose.
  defp resolve_date_range(report_config) do
    period_days = Map.get(report_config, :period_days, 30)
    reference_date = Map.get(report_config, :reference_date, Date.utc_today())

    DateRangeBuilder.compute(reference_date, period_days)
  end
  # VALIDATION: SMELL END

  defp resolve_grouping(report_config) do
    grouping = Map.get(report_config, :grouping, @default_grouping)

    if grouping in @supported_groupings do
      {:ok, grouping}
    else
      {:error, {:unsupported_grouping, grouping}}
    end
  end

  defp summarize_kpis(kpis) do
    currency = Map.get(kpis, :currency, @default_currency)

    %{
      total_revenue: Map.get(kpis, :total_revenue, 0.0),
      total_orders: Map.get(kpis, :total_orders, 0),
      average_order_value: Map.get(kpis, :average_order_value, 0.0),
      top_product_id: Map.get(kpis, :top_product_id),
      currency: currency,
      conversion_rate: Map.get(kpis, :conversion_rate, 0.0),
      refund_rate: Map.get(kpis, :refund_rate, 0.0)
    }
  end

  def list_available_groupings, do: @supported_groupings
end
```
