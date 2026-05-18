```elixir
defmodule Billing.InvoiceFormatter do
  @moduledoc """
  Provides formatting utilities for invoice data before rendering
  or exporting to PDF/CSV.
  """

  defmacro format_currency(amount, currency_code) do
    quote do
      currency = unquote(currency_code)
      value = unquote(amount)
      symbol = case currency do
        "USD" -> "$"
        "EUR" -> "€"
        "GBP" -> "£"
        "BRL" -> "R$"
        _ -> currency
      end
      formatted = :erlang.float_to_binary(value / 1.0, [{:decimals, 2}])
      "#{symbol} #{formatted}"
    end
  end

  def build_invoice_summary(invoice) do
    %{
      id: invoice.id,
      issued_at: Calendar.strftime(invoice.issued_at, "%Y-%m-%d"),
      due_at: Calendar.strftime(invoice.due_at, "%Y-%m-%d"),
      customer: invoice.customer_name,
      status: invoice.status
    }
  end

  def build_line_items(line_items) do
    Enum.map(line_items, fn item ->
      %{
        description: item.description,
        quantity: item.quantity,
        unit_price: item.unit_price,
        total: item.quantity * item.unit_price
      }
    end)
  end

  def build_totals(line_items, tax_rate, currency) do
    subtotal = Enum.reduce(line_items, 0.0, fn item, acc ->
      acc + item.quantity * item.unit_price
    end)

    tax_amount = subtotal * tax_rate
    total = subtotal + tax_amount

    require Billing.InvoiceFormatter

    %{
      subtotal: Billing.InvoiceFormatter.format_currency(subtotal, currency),
      tax: Billing.InvoiceFormatter.format_currency(tax_amount, currency),
      total: Billing.InvoiceFormatter.format_currency(total, currency)
    }
  end

  def render_text(invoice, line_items, tax_rate, currency) do
    summary = build_invoice_summary(invoice)
    items = build_line_items(line_items)
    totals = build_totals(line_items, tax_rate, currency)

    header = """
    Invoice ##{summary.id}
    Customer : #{summary.customer}
    Issued   : #{summary.issued_at}
    Due      : #{summary.due_at}
    Status   : #{summary.status}
    """

    rows =
      items
      |> Enum.map(fn i ->
        "  #{i.description} x#{i.quantity} @ #{i.unit_price} = #{i.total}"
      end)
      |> Enum.join("\n")

    footer = """
    ---
    Subtotal : #{totals.subtotal}
    Tax      : #{totals.tax}
    Total    : #{totals.total}
    """

    header <> "\n" <> rows <> "\n\n" <> footer
  end

  def export_csv(invoices, currency) do
    header = "id,customer,subtotal,status\n"

    rows =
      Enum.map(invoices, fn inv ->
        require Billing.InvoiceFormatter
        subtotal = Billing.InvoiceFormatter.format_currency(inv.subtotal, currency)
        "#{inv.id},#{inv.customer_name},#{subtotal},#{inv.status}"
      end)
      |> Enum.join("\n")

    header <> rows
  end
end
```
