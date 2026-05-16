# Code Smell: Alternative Return Types

## Metadata

- **Smell name:** Alternative Return Types
- **Expected smell location:** `Reporting.SalesReport.build/2`
- **Affected function(s):** `build/2`
- **Short explanation:** The `:as` option makes the function return a `%SalesReport{}` struct, a CSV binary string, or a list of plain maps depending on the caller's choice. These are structurally incompatible and cannot be handled uniformly downstream.

---

```elixir
defmodule MyApp.Reporting.SalesReport do
  @moduledoc """
  Builds period sales reports aggregating order data by product, region,
  and sales representative. Supports export to multiple formats for
  downstream consumption by dashboards, spreadsheet tools, and APIs.
  """

  alias MyApp.Repo
  alias MyApp.Orders.Order
  alias MyApp.Reporting.CsvSerializer
  alias MyApp.Reporting.AggregationPipeline

  defstruct [
    :period_start,
    :period_end,
    :generated_at,
    :total_revenue,
    :total_orders,
    :by_product,
    :by_region,
    :by_rep,
    :currency
  ]

  @default_currency "BRL"

  def period_params(start_date, end_date) do
    %{from: start_date, to: end_date}
  end

  # VALIDATION: SMELL START - Alternative Return Types
  # VALIDATION: This is a smell because opts[:as] changes the return type from
  # a %SalesReport{} struct (with nested aggregations), to a CSV binary string,
  # to a plain list of maps. Each format is used by different consumers (API
  # layer, file downloads, raw pipelines) but the single function signature
  # gives no indication of what type is returned, forcing callers to track
  # the option value externally.
  def build(period, opts \\ []) when is_list(opts) do
    as = Keyword.get(opts, :as, :struct)
    currency = Keyword.get(opts, :currency, @default_currency)
    group_by = Keyword.get(opts, :group_by, [:product, :region, :rep])

    orders =
      Repo.all(
        Order.within_period(period.from, period.to)
        |> Order.completed()
        |> Order.with_currency(currency)
      )

    aggregated = AggregationPipeline.run(orders, group_by)

    total_revenue = Enum.reduce(orders, Decimal.new(0), &Decimal.add(&2, &1.total))
    total_orders = length(orders)

    case as do
      :struct ->
        %__MODULE__{
          period_start: period.from,
          period_end: period.to,
          generated_at: DateTime.utc_now(),
          total_revenue: total_revenue,
          total_orders: total_orders,
          by_product: aggregated[:product],
          by_region: aggregated[:region],
          by_rep: aggregated[:rep],
          currency: currency
        }

      :csv ->
        rows =
          Enum.map(orders, fn o ->
            [o.id, o.customer_id, o.total, o.currency, o.completed_at]
          end)

        CsvSerializer.encode([["id", "customer_id", "total", "currency", "completed_at"] | rows])

      :maps ->
        Enum.map(orders, fn o ->
          %{
            order_id: o.id,
            customer_id: o.customer_id,
            total: o.total,
            currency: o.currency,
            completed_at: o.completed_at
          }
        end)
    end
  end
  # VALIDATION: SMELL END

  def compare(%__MODULE__{} = current, %__MODULE__{} = previous) do
    delta = Decimal.sub(current.total_revenue, previous.total_revenue)
    pct = Decimal.div(delta, previous.total_revenue) |> Decimal.mult(100)
    %{delta: delta, percent_change: pct}
  end

  def top_products(%__MODULE__{by_product: products}, n \\ 5) do
    products
    |> Enum.sort_by(& &1.revenue, :desc)
    |> Enum.take(n)
  end

  def summary_line(%__MODULE__{} = report) do
    "#{report.period_start} to #{report.period_end}: " <>
      "#{report.total_orders} orders, #{report.total_revenue} #{report.currency}"
  end
end
```
