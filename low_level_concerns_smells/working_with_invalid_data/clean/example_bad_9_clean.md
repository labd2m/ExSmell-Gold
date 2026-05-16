# example_bad_9_clean

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

  defp resolve_date_range(report_config) do
    period_days = Map.get(report_config, :period_days, 30)
    reference_date = Map.get(report_config, :reference_date, Date.utc_today())

    DateRangeBuilder.compute(reference_date, period_days)
  end

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
