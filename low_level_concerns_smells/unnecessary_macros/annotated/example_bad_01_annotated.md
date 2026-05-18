# Annotated Example 01 — Unnecessary Macros

## Metadata

- **Smell name:** Unnecessary macros
- **Expected smell location:** `defmacro format_currency/2` inside `BillingFormatter`
- **Affected function(s):** `format_currency/2`
- **Short explanation:** The macro only performs arithmetic and string formatting, operations that require no compile-time transformation. A regular function would be simpler, more readable, and equally correct.

---

```elixir
defmodule BillingFormatter do
  @moduledoc """
  Provides formatting utilities for billing documents,
  invoices, and financial reports.
  """

  # VALIDATION: SMELL START - Unnecessary macros
  # VALIDATION: This is a smell because format_currency/2 only does arithmetic
  # division and string interpolation — no compile-time transformation is
  # needed. A plain `def` function would be simpler and equally effective.
  defmacro format_currency(amount_cents, currency_code) do
    quote do
      currency = unquote(currency_code)
      cents = unquote(amount_cents)
      whole = div(cents, 100)
      remainder = rem(cents, 100)
      "#{currency} #{whole}.#{String.pad_leading(Integer.to_string(remainder), 2, "0")}"
    end
  end
  # VALIDATION: SMELL END

  defmacro format_percentage(value, decimals) do
    quote do
      Float.round(unquote(value) * 100.0, unquote(decimals))
      |> Float.to_string()
      |> Kernel.<>("%")
    end
  end
end

defmodule Billing.Invoice do
  @moduledoc """
  Represents a billing invoice and provides rendering logic
  for generating human-readable invoice summaries.
  """

  require BillingFormatter

  defstruct [
    :id,
    :customer_id,
    :line_items,
    :issued_at,
    :due_at,
    :currency,
    :status
  ]

  @type t :: %__MODULE__{
          id: String.t(),
          customer_id: String.t(),
          line_items: list(map()),
          issued_at: DateTime.t(),
          due_at: DateTime.t(),
          currency: String.t(),
          status: :draft | :issued | :paid | :overdue
        }

  @doc """
  Calculates the total amount in cents from all line items.
  """
  @spec total_cents(t()) :: non_neg_integer()
  def total_cents(%__MODULE__{line_items: items}) do
    Enum.reduce(items, 0, fn item, acc ->
      acc + item.unit_price_cents * item.quantity
    end)
  end

  @doc """
  Renders a summary string for the invoice suitable for display
  in dashboards or email notifications.
  """
  @spec render_summary(t()) :: String.t()
  def render_summary(%__MODULE__{} = invoice) do
    total = total_cents(invoice)
    formatted = BillingFormatter.format_currency(total, invoice.currency)

    """
    Invoice ##{invoice.id}
    Customer: #{invoice.customer_id}
    Status: #{invoice.status}
    Total: #{formatted}
    Due: #{DateTime.to_date(invoice.due_at)}
    """
  end

  @doc """
  Checks whether the invoice is past its due date.
  """
  @spec overdue?(t()) :: boolean()
  def overdue?(%__MODULE__{due_at: due_at, status: status}) do
    status != :paid and DateTime.compare(DateTime.utc_now(), due_at) == :gt
  end

  @doc """
  Returns a list of line item descriptions with individual totals formatted.
  """
  @spec render_line_items(t()) :: list(String.t())
  def render_line_items(%__MODULE__{line_items: items, currency: currency}) do
    Enum.map(items, fn item ->
      total_cents = item.unit_price_cents * item.quantity
      formatted = BillingFormatter.format_currency(total_cents, currency)
      "#{item.description} x#{item.quantity} = #{formatted}"
    end)
  end
end
```
