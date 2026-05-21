# Annotated Example — Untested Polymorphic Behaviors

## Metadata

- **Smell name:** Untested polymorphic behaviors
- **Expected smell location:** `Billing.InvoiceFormatter.format_amount/1`
- **Affected function(s):** `format_amount/1`
- **Short explanation:** `format_amount/1` calls `to_string/1`, which dispatches through the
  `String.Chars` protocol. The function accepts any term without a guard clause. Floats and
  integers produce correct output, but passing a `Map`, `Tuple`, `PID`, or `nil` either raises
  `Protocol.UndefinedError` at runtime or silently produces a meaningless monetary string
  (e.g., passing an already-formatted binary like `"$9.99"` yields `"$$9.99"`). The caller has
  no contract to rely on, and the failure surface is invisible until runtime.

---

```elixir
defmodule Billing.InvoiceFormatter do
  @moduledoc """
  Handles text-based formatting of invoice data for PDF generation,
  plain-text email bodies, and CSV export. All monetary values are
  expected to be expressed in the account's base currency unit (e.g., USD dollars as a float).
  """

  alias Billing.{Invoice, LineItem}

  @currency_symbol "$"
  @col_desc   40
  @col_qty     8
  @col_price  12
  @col_total  12
  @row_width  (@col_desc + @col_qty + @col_price + @col_total)

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @doc "Renders a full invoice as a plain-text string."
  def render_invoice(%Invoice{} = invoice) do
    sections = [
      render_header(invoice),
      render_column_labels(),
      render_divider(),
      render_line_items(invoice.line_items),
      render_divider(),
      render_summary(invoice)
    ]

    Enum.join(sections, "\n")
  end

  @doc "Renders the invoice header block."
  def render_header(%Invoice{} = invoice) do
    """
    Invoice #: #{invoice.number}
    Date     : #{Calendar.strftime(invoice.issued_at, "%B %d, %Y")}
    Due      : #{Calendar.strftime(invoice.due_at, "%B %d, %Y")}
    Bill To  : #{invoice.customer_name} <#{invoice.customer_email}>
    """
  end

  @doc "Renders all line-item rows."
  def render_line_items(line_items) when is_list(line_items) do
    line_items
    |> Enum.map(&render_line_item/1)
    |> Enum.join("\n")
  end

  @doc "Renders a single line-item row."
  def render_line_item(%LineItem{} = item) do
    total = Float.round(item.quantity * item.unit_price, 2)

    [
      pad(item.description, @col_desc),
      pad(Integer.to_string(item.quantity), @col_qty),
      pad(format_amount(item.unit_price), @col_price),
      pad(format_amount(total), @col_total)
    ]
    |> Enum.join("")
  end

  @doc "Renders the invoice totals block."
  def render_summary(%Invoice{} = invoice) do
    subtotal = compute_subtotal(invoice.line_items)
    tax      = Float.round(subtotal * invoice.tax_rate / 100.0, 2)
    total    = Float.round(subtotal + tax, 2)

    label_width = @col_desc + @col_qty + @col_price

    [
      pad("Subtotal:", label_width) <> pad(format_amount(subtotal), @col_total),
      pad("Tax (#{invoice.tax_rate}%):", label_width) <> pad(format_amount(tax), @col_total),
      render_divider(),
      pad("Total Due:", label_width) <> pad(format_amount(total), @col_total)
    ]
    |> Enum.join("\n")
  end

  # VALIDATION: SMELL START - Untested polymorphic behaviors
  # VALIDATION: This is a smell because format_amount/1 invokes to_string/1, which
  # VALIDATION: relies on the String.Chars protocol. There is no guard clause or
  # VALIDATION: pattern match restricting the input type. Numeric types (Integer,
  # VALIDATION: Float) work correctly, but any caller that passes a Map, Tuple,
  # VALIDATION: List, or PID will trigger Protocol.UndefinedError at runtime with
  # VALIDATION: no indication of which call site was responsible. Additionally,
  # VALIDATION: passing a binary that already contains a dollar sign produces a
  # VALIDATION: silently wrong result (e.g., "$$9.99") instead of an error.
  @doc """
  Formats a numeric monetary amount as a currency string.

  ## Examples

      iex> Billing.InvoiceFormatter.format_amount(9.5)
      "$9.50"

      iex> Billing.InvoiceFormatter.format_amount(1200)
      "$1200.00"
  """
  def format_amount(amount) do
    raw =
      to_string(amount)
      |> String.split(".")
      |> case do
        [whole]      -> whole <> ".00"
        [whole, dec] -> whole <> "." <> String.pad_trailing(String.slice(dec, 0, 2), 2, "0")
      end

    @currency_symbol <> raw
  end
  # VALIDATION: SMELL END

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp compute_subtotal(line_items) do
    Enum.reduce(line_items, 0.0, fn item, acc ->
      acc + item.quantity * item.unit_price
    end)
    |> Float.round(2)
  end

  defp render_column_labels do
    pad("Description", @col_desc) <>
      pad("Qty", @col_qty) <>
      pad("Unit Price", @col_price) <>
      pad("Total", @col_total)
  end

  defp render_divider, do: String.duplicate("-", @row_width)

  defp pad(text, width) do
    text
    |> to_string()
    |> String.slice(0, width)
    |> String.pad_trailing(width)
  end
end
```
