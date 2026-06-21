```elixir
defmodule MyApp.Billing.InvoiceRenderer do
  @moduledoc """
  Generates PDF-ready invoice data maps from `Invoice` domain structs.
  Rendering concerns (line item formatting, tax calculations, totals,
  and address layout) are isolated in dedicated private functions so that
  each transformation can be reasoned about and tested in isolation.

  The output is a plain map that can be handed directly to any PDF
  templating library (e.g., ChromicPDF, HTMLToPDF) without further processing.
  """

  alias MyApp.Billing.{Invoice, LineItem, TaxRate}

  @type money_string :: String.t()

  @type rendered_line :: %{
          description: String.t(),
          quantity: pos_integer(),
          unit_price: money_string(),
          subtotal: money_string()
        }

  @type rendered_invoice :: %{
          invoice_number: String.t(),
          issued_on: String.t(),
          due_on: String.t(),
          billed_to: map(),
          billed_from: map(),
          lines: [rendered_line()],
          subtotal: money_string(),
          tax_lines: [map()],
          total: money_string(),
          notes: String.t() | nil
        }

  @doc """
  Converts an `Invoice` struct into a fully rendered map suitable for
  PDF template injection. All monetary values are formatted as display
  strings (e.g., `"$1,234.56"`).
  """
  @spec render(Invoice.t()) :: rendered_invoice()
  def render(%Invoice{} = invoice) do
    lines = Enum.map(invoice.line_items, &render_line/1)
    subtotal_cents = sum_subtotals(invoice.line_items)
    tax_lines = compute_tax_lines(subtotal_cents, invoice.tax_rates)
    total_cents = subtotal_cents + sum_tax_amounts(tax_lines)

    %{
      invoice_number: invoice.number,
      issued_on: format_date(invoice.issued_on),
      due_on: format_date(invoice.due_on),
      billed_to: render_address(invoice.customer),
      billed_from: render_address(invoice.vendor),
      lines: lines,
      subtotal: format_cents(subtotal_cents),
      tax_lines: Enum.map(tax_lines, &format_tax_line/1),
      total: format_cents(total_cents),
      notes: invoice.notes
    }
  end

  @spec render_line(LineItem.t()) :: rendered_line()
  defp render_line(item) do
    %{
      description: item.description,
      quantity: item.quantity,
      unit_price: format_cents(item.unit_price_cents),
      subtotal: format_cents(item.unit_price_cents * item.quantity)
    }
  end

  @spec sum_subtotals([LineItem.t()]) :: non_neg_integer()
  defp sum_subtotals(items) do
    Enum.sum_by(items, fn i -> i.unit_price_cents * i.quantity end)
  end

  @spec compute_tax_lines(non_neg_integer(), [TaxRate.t()]) :: [map()]
  defp compute_tax_lines(subtotal_cents, tax_rates) do
    Enum.map(tax_rates, fn rate ->
      amount = round(subtotal_cents * rate.rate / 100)
      %{label: rate.label, rate: rate.rate, amount_cents: amount}
    end)
  end

  @spec sum_tax_amounts([map()]) :: non_neg_integer()
  defp sum_tax_amounts(tax_lines) do
    Enum.sum_by(tax_lines, & &1.amount_cents)
  end

  @spec format_tax_line(map()) :: map()
  defp format_tax_line(line) do
    %{
      label: "#{line.label} (#{line.rate}%)",
      amount: format_cents(line.amount_cents)
    }
  end

  @spec render_address(map()) :: map()
  defp render_address(entity) do
    %{
      name: entity.name,
      line1: entity.address_line1,
      line2: entity.address_line2,
      city: entity.city,
      state: entity.state,
      postal_code: entity.postal_code,
      country: entity.country
    }
  end

  @spec format_date(Date.t()) :: String.t()
  defp format_date(date), do: Calendar.strftime(date, "%B %-d, %Y")

  @spec format_cents(non_neg_integer()) :: money_string()
  defp format_cents(cents) do
    dollars = div(cents, 100)
    cents_remainder = String.pad_leading(Integer.to_string(rem(cents, 100)), 2, "0")
    formatted_dollars = dollars |> Integer.to_string() |> insert_thousand_separators()
    "$#{formatted_dollars}.#{cents_remainder}"
  end

  @spec insert_thousand_separators(String.t()) :: String.t()
  defp insert_thousand_separators(digits) do
    digits
    |> String.reverse()
    |> String.replace(~r/(\d{3})(?=\d)/, "\\1,")
    |> String.reverse()
  end
end
```
