```elixir
defmodule Billing.InvoiceProcessor do
  @moduledoc """
  Handles invoice creation, line-item aggregation, and discount application
  for the billing subsystem.
  """

  alias Billing.LineItem
  alias Billing.Invoice

  @tax_rate 0.15

  @doc """
  Builds a full invoice from a list of raw order lines, applying any
  provided discount map before computing tax and total.
  """
  def build_invoice(order_id, customer_id, raw_lines, discount \\ %{}) do
    line_items = Enum.map(raw_lines, &build_line_item/1)
    subtotal = compute_subtotal(line_items)

    discounted_subtotal = apply_discount(subtotal, discount)
    tax = Float.round(discounted_subtotal * @tax_rate, 2)
    total = Float.round(discounted_subtotal + tax, 2)

    %Invoice{
      order_id: order_id,
      customer_id: customer_id,
      line_items: line_items,
      subtotal: subtotal,
      discount_applied: subtotal - discounted_subtotal,
      tax: tax,
      total: total,
      issued_at: DateTime.utc_now()
    }
  end

  @doc """
  Applies a discount to the given subtotal.

  The discount map may contain:
    - `:type`  — either `"percentage"` or `"fixed"`
    - `:value` — the magnitude of the discount
  """
  def apply_discount(subtotal, discount) do
    discount_type  = discount[:type]
    discount_value = discount[:value]

    cond do
      discount_type == "percentage" ->
        deduction = Float.round(subtotal * (discount_value / 100), 2)
        Float.round(subtotal - deduction, 2)

      discount_type == "fixed" ->
        max(0.0, Float.round(subtotal - discount_value, 2))

      true ->
        subtotal
    end
  end

  @doc """
  Formats an invoice as a printable string summary.
  """
  def format_summary(%Invoice{} = invoice) do
    lines =
      Enum.map_join(invoice.line_items, "\n", fn li ->
        "  #{li.description} x#{li.quantity} @ #{li.unit_price} = #{li.total}"
      end)

    """
    ========================================
    Invoice ##{invoice.order_id}
    Customer: #{invoice.customer_id}
    ----------------------------------------
    #{lines}
    ----------------------------------------
    Subtotal : #{invoice.subtotal}
    Discount : -#{invoice.discount_applied}
    Tax (15%): #{invoice.tax}
    TOTAL    : #{invoice.total}
    Issued   : #{invoice.issued_at}
    ========================================
    """
  end

  ## Private helpers

  defp build_line_item(%{sku: sku, description: desc, quantity: qty, unit_price: price}) do
    %LineItem{
      sku: sku,
      description: desc,
      quantity: qty,
      unit_price: price,
      total: Float.round(qty * price, 2)
    }
  end

  defp compute_subtotal(line_items) do
    line_items
    |> Enum.map(& &1.total)
    |> Enum.sum()
    |> Float.round(2)
  end
end
```
