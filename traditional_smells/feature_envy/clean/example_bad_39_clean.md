```elixir
defmodule Billing.InvoiceFormatter do
  @moduledoc """
  Transforms raw invoice data into structured maps for PDF rendering
  and HTML display in the customer billing portal.
  """

  alias Billing.{Invoice, LineItem, TaxProfile}
  alias Accounts.Customer
  alias Catalog.Product

  @date_format "{YYYY}-{0M}-{0D}"
  @currency_symbol "$"


  @doc """
  Builds a complete invoice render map from a persisted invoice record.
  Returns a nested map suitable for passing to a Phoenix template or
  a PDF generation library such as ChromicPDF.
  """
  @spec render_invoice(String.t()) :: map()
  def render_invoice(invoice_id) do
    invoice    = Invoice.get!(invoice_id)
    customer   = Invoice.fetch_customer!(invoice)
    line_items = Invoice.list_line_items(invoice)
    payments   = Invoice.list_payments(invoice)

    %{
      invoice_number: invoice.number,
      status:         invoice.status,
      issued_at:      format_date(invoice.issued_at),
      due_at:         format_date(invoice.due_at),
      customer:       render_customer_block(customer),
      line_items:     Enum.map(line_items, &format_line_item/1),
      payments:       Enum.map(payments, &render_payment_entry/1),
      totals:         render_totals(invoice),
      footer_note:    invoice.memo
    }
  end


  defp format_line_item(item) do
    product     = LineItem.get_product(item)
    tax_profile = LineItem.get_tax_profile(item)
    tax_rate    = TaxProfile.effective_rate(tax_profile, item.region_code)
    discount    = LineItem.get_applied_discount(item)

    subtotal = Decimal.mult(item.unit_price, item.quantity)

    discount_amount =
      if discount do
        Decimal.mult(subtotal, discount.rate)
      else
        Decimal.new("0.00")
      end

    taxable_amount = Decimal.sub(subtotal, discount_amount)
    tax_amount     = Decimal.mult(taxable_amount, tax_rate)
    line_total     = Decimal.add(taxable_amount, tax_amount)

    %{
      sku:          product.sku,
      description:  product.name,
      category:     Product.category_label(product),
      unit_label:   LineItem.unit_label(item),
      quantity:     item.quantity,
      unit_price:   format_money(item.unit_price),
      subtotal:     format_money(subtotal),
      discount:     format_optional_money(discount_amount, discount),
      tax_rate:     format_percent(tax_rate),
      tax_amount:   format_money(tax_amount),
      line_total:   format_money(line_total),
      notes:        item.fulfillment_notes
    }
  end

  defp render_customer_block(customer) do
    %{
      id:            customer.id,
      display_name:  Customer.display_name(customer),
      billing_email: customer.billing_email,
      address:       Customer.formatted_address(customer),
      tax_id:        customer.tax_id
    }
  end

  defp render_payment_entry(payment) do
    %{
      method:     payment.method,
      amount:     format_money(payment.amount),
      paid_at:    format_date(payment.paid_at),
      reference:  payment.external_reference
    }
  end

  defp render_totals(invoice) do
    %{
      subtotal:       format_money(invoice.subtotal),
      discount_total: format_money(invoice.discount_total),
      tax_total:      format_money(invoice.tax_total),
      grand_total:    format_money(invoice.grand_total),
      amount_paid:    format_money(invoice.amount_paid),
      amount_due:     format_money(invoice.amount_due)
    }
  end

  defp format_date(nil), do: nil
  defp format_date(%DateTime{} = dt), do: Calendar.strftime(dt, @date_format)
  defp format_date(%Date{} = d),      do: Calendar.strftime(d, @date_format)

  defp format_money(%Decimal{} = value) do
    rounded = Decimal.round(value, 2)
    "#{@currency_symbol}#{Decimal.to_string(rounded, :normal)}"
  end

  defp format_optional_money(_amount, nil),       do: nil
  defp format_optional_money(amount, _discount),  do: format_money(amount)

  defp format_percent(%Decimal{} = rate) do
    rate
    |> Decimal.mult(100)
    |> Decimal.round(2)
    |> Decimal.to_string(:normal)
    |> Kernel.<>("%")
  end
end
```
