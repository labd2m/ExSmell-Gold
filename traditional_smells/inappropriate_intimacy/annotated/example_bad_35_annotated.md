# Annotated Example — Inappropriate Intimacy

## Metadata

- **Smell name:** Inappropriate Intimacy
- **Expected smell location:** `build_discount_impact/1` in `Reporting.SalesReportBuilder`
- **Affected function(s):** `build_discount_impact/1`
- **Short explanation:** `build_discount_impact/1` directly accesses internal fields of
  `LineItem` (`discount_code_id`, `unit_price`, `quantity`, `discounted_unit_price`) and
  `DiscountCode` (`type`, `rate`, `fixed_amount`) to compute how much each coupon saved.
  The saving-amount calculation is business logic that belongs inside `DiscountCode` or
  `LineItem`; the reporter should only ask for a pre-computed discount value, not
  reconstruct the discount formula from raw internal fields.

## Code

```elixir
defmodule Reporting.SalesReportBuilder do
  @moduledoc """
  Compiles period-based sales reports including revenue breakdown,
  discount impact analysis, and top product summaries.
  """

  alias Reporting.{SalesReport, ReportExport}
  alias Commerce.{Order, LineItem, DiscountCode}

  @default_top_n 10

  def build(opts \\ []) do
    from  = Keyword.fetch!(opts, :from)
    to    = Keyword.fetch!(opts, :to)
    top_n = Keyword.get(opts, :top_n, @default_top_n)

    orders = Order.list(status: :completed, from: from, to: to)

    %SalesReport{
      period_start:    from,
      period_end:      to,
      generated_at:    DateTime.utc_now(),
      revenue_summary: build_revenue_summary(orders),
      discount_impact: build_discount_impact(orders),
      top_products:    build_top_products(orders, top_n)
    }
  end

  def export(%SalesReport{} = report, format) when format in [:pdf, :csv, :xlsx] do
    ReportExport.generate(report, format)
  end

  def build_revenue_summary(orders) do
    Enum.reduce(orders, %{gross: Decimal.new(0), net: Decimal.new(0), count: 0}, fn order, acc ->
      %{
        gross: Decimal.add(acc.gross, order.gross_total),
        net:   Decimal.add(acc.net,   order.net_total),
        count: acc.count + 1
      }
    end)
  end

  def build_discount_impact(orders) do
    # VALIDATION: SMELL START - Inappropriate Intimacy
    # VALIDATION: This is a smell because build_discount_impact directly reads internal
    # VALIDATION: fields of LineItem (discount_code_id, unit_price, quantity,
    # VALIDATION: discounted_unit_price) and DiscountCode (type, rate, fixed_amount) to
    # VALIDATION: reconstruct the discount formula. The amount saved per line is business
    # VALIDATION: logic that belongs to DiscountCode or LineItem; this function should
    # VALIDATION: receive a pre-computed value rather than repeating internal logic.
    orders
    |> Enum.flat_map(fn order ->
      items = LineItem.for_order(order.id)

      Enum.flat_map(items, fn item ->
        if not is_nil(item.discount_code_id) do
          code = DiscountCode.find(item.discount_code_id)

          saved =
            case code.type do
              :percentage ->
                base = Decimal.mult(item.unit_price, Decimal.new(item.quantity))
                Decimal.mult(base, code.rate)

              :fixed ->
                Decimal.mult(code.fixed_amount, Decimal.new(item.quantity))

              :bogo ->
                free_units = div(item.quantity, 2)
                Decimal.mult(item.discounted_unit_price, Decimal.new(free_units))
            end

          [%{code: code.code, product_id: item.product_id, saved: saved}]
        else
          []
        end
      end)
    end)
    |> Enum.group_by(& &1.code)
    |> Enum.map(fn {code, entries} ->
      total_saved = Enum.reduce(entries, Decimal.new(0), &Decimal.add(&2, &1.saved))
      %{code: code, total_saved: total_saved, times_applied: length(entries)}
    end)
    |> Enum.sort_by(& &1.total_saved, :desc)
    # VALIDATION: SMELL END
  end

  def build_top_products(orders, n) do
    orders
    |> Enum.flat_map(fn order -> LineItem.for_order(order.id) end)
    |> Enum.group_by(& &1.product_id)
    |> Enum.map(fn {product_id, items} ->
      quantity = Enum.sum(Enum.map(items, & &1.quantity))
      revenue  = Enum.reduce(items, Decimal.new(0), fn i, acc -> Decimal.add(acc, i.line_total) end)
      %{product_id: product_id, total_quantity: quantity, total_revenue: revenue}
    end)
    |> Enum.sort_by(& &1.total_revenue, :desc)
    |> Enum.take(n)
  end

  def summary_text(%SalesReport{} = report) do
    """
    Sales Report: #{Date.to_string(report.period_start)} – #{Date.to_string(report.period_end)}
    Gross Revenue : #{report.revenue_summary.gross}
    Net Revenue   : #{report.revenue_summary.net}
    Orders        : #{report.revenue_summary.count}
    Generated at  : #{report.generated_at}
    """
  end

  def compare(report_a, report_b) do
    delta = Decimal.sub(report_b.revenue_summary.net, report_a.revenue_summary.net)
    pct   = if Decimal.equal?(report_a.revenue_summary.net, Decimal.new(0)) do
      nil
    else
      Decimal.div(delta, report_a.revenue_summary.net) |> Decimal.mult(Decimal.new(100))
    end

    %{absolute_change: delta, percentage_change: pct}
  end
end
```
