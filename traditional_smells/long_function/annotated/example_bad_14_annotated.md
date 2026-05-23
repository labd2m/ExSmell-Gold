# Annotated Example — Long Function

## Metadata

- **Smell name:** Long Function
- **Expected smell location:** `Reporting.ProductPerformance.compile/3`
- **Affected function(s):** `compile/3`
- **Short explanation:** The `compile/3` function embeds date parsing, order data fetching, per-product aggregation, return rate calculation, ranking, top-N selection, PDF-export preparation, and report persistence all in one giant body. Every one of these phases is a separate concern that should be handled by its own focused function.

---

```elixir
defmodule Reporting.ProductPerformance do
  @moduledoc """
  Compiles product-level performance reports covering revenue, units sold,
  return rates, and ranking within a given date range.
  """

  alias Reporting.{ReportRecord, Repo}
  alias Sales.{Order, ReturnRequest}
  alias Integrations.PdfExporter
  require Logger

  @top_n_products 20

  # VALIDATION: SMELL START - Long Function
  # VALIDATION: This is a smell because `compile/3` performs date-range construction,
  # VALIDATION: order and return data fetching, per-SKU aggregation, return rate
  # VALIDATION: computation, ranking and slicing, export payload assembly,
  # VALIDATION: PDF generation, and report record persistence all in one function.
  def compile(start_date, end_date, opts \\ []) do
    format = Keyword.get(opts, :format, :json)
    requested_by = Keyword.get(opts, :requested_by, "system")

    Logger.info("Compiling product performance report #{start_date} – #{end_date}")

    # --- Validate date range ---
    if Date.compare(start_date, end_date) == :gt do
      {:error, :invalid_date_range}
    else
      days_in_range = Date.diff(end_date, start_date) + 1

      # --- Fetch completed orders in range ---
      orders =
        Order
        |> Order.completed()
        |> Order.between_dates(start_date, end_date)
        |> Repo.all()
        |> Repo.preload(:items)

      # --- Fetch returns in range ---
      returns =
        ReturnRequest
        |> ReturnRequest.approved()
        |> ReturnRequest.between_dates(start_date, end_date)
        |> Repo.all()
        |> Repo.preload(:items)

      # --- Aggregate sales per SKU ---
      sales_by_sku =
        Enum.reduce(orders, %{}, fn order, acc ->
          Enum.reduce(order.items, acc, fn item, inner ->
            entry = Map.get(inner, item.sku, %{revenue: 0.0, units: 0, orders: 0})
            Map.put(inner, item.sku, %{
              revenue: entry.revenue + item.unit_price * item.quantity,
              units: entry.units + item.quantity,
              orders: entry.orders + 1,
              name: item.name,
              category: item.category
            })
          end)
        end)

      # --- Aggregate returns per SKU ---
      returns_by_sku =
        Enum.reduce(returns, %{}, fn ret, acc ->
          Enum.reduce(ret.items, acc, fn item, inner ->
            entry = Map.get(inner, item.sku, %{returned_units: 0})
            Map.put(inner, item.sku, %{returned_units: entry.returned_units + item.quantity})
          end)
        end)

      # --- Build product rows ---
      product_rows =
        Enum.map(sales_by_sku, fn {sku, sales} ->
          returned = get_in(returns_by_sku, [sku, :returned_units]) || 0
          return_rate = if sales.units > 0, do: Float.round(returned / sales.units * 100, 2), else: 0.0
          avg_revenue_per_day = if days_in_range > 0, do: Float.round(sales.revenue / days_in_range, 2), else: 0.0

          %{
            sku: sku,
            name: sales.name,
            category: sales.category,
            total_revenue: Float.round(sales.revenue, 2),
            total_units: sales.units,
            total_orders: sales.orders,
            returned_units: returned,
            return_rate_pct: return_rate,
            avg_daily_revenue: avg_revenue_per_day
          }
        end)
        |> Enum.sort_by(& &1.total_revenue, :desc)
        |> Enum.take(@top_n_products)

      # --- Build report payload ---
      report_data = %{
        period_start: start_date,
        period_end: end_date,
        days: days_in_range,
        total_orders: length(orders),
        total_products_sold: map_size(sales_by_sku),
        top_products: product_rows,
        generated_at: DateTime.utc_now(),
        requested_by: requested_by
      }

      # --- Export if needed ---
      export_url =
        if format == :pdf do
          case PdfExporter.export("product_performance", report_data) do
            {:ok, url} -> url
            {:error, _} -> nil
          end
        else
          nil
        end

      # --- Persist report record ---
      {:ok, record} =
        Repo.insert(ReportRecord.changeset(%ReportRecord{}, %{
          type: "product_performance",
          parameters: %{start_date: start_date, end_date: end_date},
          data: report_data,
          export_url: export_url,
          generated_by: requested_by,
          generated_at: DateTime.utc_now()
        }))

      Logger.info("Product performance report #{record.id} compiled")
      {:ok, %{report: report_data, record_id: record.id, export_url: export_url}}
    end
  end
  # VALIDATION: SMELL END
end
```
