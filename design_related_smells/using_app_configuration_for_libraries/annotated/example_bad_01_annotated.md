# Annotated Example 01

- **Smell name:** Using App Configuration for libraries
- **Expected smell location:** `InvoiceFormatter.format_line_items/1` and `InvoiceFormatter.format_total/1`
- **Affected functions:** `format_line_items/1`, `format_total/1`
- **Short explanation:** The library reads `:currency_symbol` and `:decimal_places` directly from the Application Environment instead of accepting them as parameters. This forces all callers to share the same formatting settings, making it impossible to format invoices in multiple currencies or precisions within the same application.

```elixir
defmodule InvoiceFormatter do
  @moduledoc """
  A library for formatting invoice data into human-readable strings.
  Intended to be used across billing, reporting, and customer-facing modules.
  """

  alias InvoiceFormatter.LineItem

  defmodule LineItem do
    @enforce_keys [:description, :quantity, :unit_price]
    defstruct [:description, :quantity, :unit_price, :discount]
  end

  defmodule Invoice do
    @enforce_keys [:number, :issued_at, :customer_name, :line_items]
    defstruct [:number, :issued_at, :customer_name, :line_items, :notes]
  end

  @doc """
  Formats a complete invoice into a printable map with string values.
  """
  def format(%Invoice{} = invoice) do
    %{
      number: invoice.number,
      issued_at: Calendar.strftime(invoice.issued_at, "%Y-%m-%d"),
      customer: invoice.customer_name,
      line_items: format_line_items(invoice.line_items),
      total: format_total(invoice.line_items),
      notes: invoice.notes || ""
    }
  end

  @doc """
  Formats a list of line items into display-ready maps.
  """
  # VALIDATION: SMELL START - Using App Configuration for libraries
  # VALIDATION: This is a smell because the library retrieves :currency_symbol
  # and :decimal_places from the global Application Environment instead of
  # accepting them as optional parameters. Every caller of format_line_items/1
  # or format_total/1 is forced to use the same currency symbol and precision,
  # making it impossible to render invoices in multiple currencies in the same app.
  def format_line_items(line_items) when is_list(line_items) do
    currency = Application.fetch_env!(:invoice_formatter, :currency_symbol)
    decimals = Application.fetch_env!(:invoice_formatter, :decimal_places)

    Enum.map(line_items, fn item ->
      subtotal = item.quantity * item.unit_price
      discount = item.discount || 0
      net = subtotal - discount

      %{
        description: item.description,
        quantity: item.quantity,
        unit_price: format_amount(item.unit_price, currency, decimals),
        discount: format_amount(discount, currency, decimals),
        subtotal: format_amount(net, currency, decimals)
      }
    end)
  end

  @doc """
  Computes and formats the invoice total from a list of line items.
  """
  def format_total(line_items) when is_list(line_items) do
    currency = Application.fetch_env!(:invoice_formatter, :currency_symbol)
    decimals = Application.fetch_env!(:invoice_formatter, :decimal_places)

    total =
      Enum.reduce(line_items, 0, fn item, acc ->
        subtotal = item.quantity * item.unit_price
        discount = item.discount || 0
        acc + subtotal - discount
      end)

    format_amount(total, currency, decimals)
  end
  # VALIDATION: SMELL END

  @doc """
  Generates a plain-text summary for email delivery.
  """
  def to_text(%Invoice{} = invoice) do
    formatted = format(invoice)

    lines =
      Enum.map(formatted.line_items, fn li ->
        "  #{li.description} x#{li.quantity} = #{li.subtotal}"
      end)

    """
    Invoice ##{formatted.number}
    Date: #{formatted.issued_at}
    Customer: #{formatted.customer}

    Items:
    #{Enum.join(lines, "\n")}

    Total: #{formatted.total}
    #{if formatted.notes != "", do: "\nNotes: #{formatted.notes}", else: ""}
    """
  end

  # --- Private helpers ---

  defp format_amount(amount, currency, decimals) do
    "#{currency}#{:erlang.float_to_binary(amount / 1, decimals: decimals)}"
  end
end
```
