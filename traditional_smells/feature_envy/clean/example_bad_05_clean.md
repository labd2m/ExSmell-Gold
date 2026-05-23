```elixir
defmodule Reporting.SalesReport do
  alias Reporting.{Report, ReportFormatter}
  alias Orders.{Order, LineItem}

  @doc """
  Generates a sales report for a given date range and optional format.
  Supported formats: :json, :csv, :pdf.
  """
  def generate(start_date, end_date, opts \\ []) do
    orders = Order.list_completed(start_date, end_date)
    format = Keyword.get(opts, :format, :json)

    report_data = %{
      period: %{from: start_date, to: end_date},
      total_orders: length(orders),
      revenue: compute_total_revenue(orders),
      line_item_summary: summarize_line_items_for_orders(orders),
      top_products: top_products(orders, limit: 10)
    }

    report =
      Report.create(%{
        type: :sales,
        period_start: start_date,
        period_end: end_date,
        data: report_data
      })

    ReportFormatter.format(report, format)
  end

  @doc """
  Shortcut to generate a CSV export of the sales report.
  """
  def export_csv(start_date, end_date) do
    generate(start_date, end_date, format: :csv)
  end

  @doc """
  Returns a quick revenue total for a date range without generating a full report.
  """
  def quick_revenue_total(start_date, end_date) do
    Order.list_completed(start_date, end_date)
    |> compute_total_revenue()
  end

  defp compute_total_revenue(orders) do
    Enum.reduce(orders, Decimal.new(0), fn order, acc ->
      Decimal.add(acc, order.total_amount)
    end)
  end

  defp top_products(orders, limit: limit) do
    orders
    |> Enum.flat_map(fn order -> LineItem.list_for_order(order.id) end)
    |> Enum.group_by(& &1.product_id)
    |> Enum.map(fn {product_id, items} ->
      %{
        product_id: product_id,
        quantity_sold: Enum.sum(Enum.map(items, & &1.quantity)),
        revenue:
          Enum.reduce(items, Decimal.new(0), fn i, acc ->
            Decimal.add(acc, Decimal.mult(i.unit_price, i.quantity))
          end)
      }
    end)
    |> Enum.sort_by(& &1.revenue, :desc)
    |> Enum.take(limit)
  end

  defp summarize_line_items_for_orders(orders) do
    orders
    |> Enum.flat_map(fn order -> LineItem.list_for_order(order.id) end)
    |> Enum.map(&summarize_line_item/1)
  end

  defp summarize_line_item(item) do
    product_name = LineItem.product_name(item)
    unit_price_with_tax = LineItem.unit_price_with_tax(item)
    discount = LineItem.discount_applied(item)
    net_total = LineItem.net_total(item)
    category = LineItem.category(item)

    %{
      product_id: item.product_id,
      product_name: product_name,
      category: category,
      quantity: item.quantity,
      unit_price: item.unit_price,
      unit_price_with_tax: unit_price_with_tax,
      discount: discount,
      net_total: net_total
    }
  end

  defp format_date_range(start_date, end_date) do
    "#{Date.to_string(start_date)} to #{Date.to_string(end_date)}"
  end
end
```
