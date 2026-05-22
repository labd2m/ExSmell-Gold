# example_bad_01_annotated.md

## Metadata

- **Smell Name:** "Use" instead of "import"
- **Expected Smell Location:** `Billing.InvoiceProcessor` module, `use Billing.FormatHelpers` directive
- **Affected Function(s):** Module-level directive (affects the entire `Billing.InvoiceProcessor` module)
- **Short Explanation:** `Billing.InvoiceProcessor` uses `use Billing.FormatHelpers` only to gain access to invoice-formatting functions. However, `Billing.FormatHelpers.__using__/1` silently injects `import Billing.CurrencyUtils` into the caller, propagating a hidden dependency. Since the client needs nothing beyond callable functions, `import Billing.FormatHelpers` would be clearer and would not introduce unexpected transitive dependencies.

## Code

```elixir
defmodule Billing.CurrencyUtils do
  @moduledoc """
  Low-level currency arithmetic and formatting helpers.
  """

  def format_currency(amount_in_cents) when is_integer(amount_in_cents) do
    dollars = div(amount_in_cents, 100)
    cents   = amount_in_cents |> rem(100) |> abs()
    "$#{dollars}.#{String.pad_leading(to_string(cents), 2, "0")}"
  end

  def parse_currency(string) when is_binary(string) do
    string
    |> String.replace(~r/[^\d]/, "")
    |> String.to_integer()
  end

  def cents_to_float(amount_in_cents), do: amount_in_cents / 100
end

defmodule Billing.FormatHelpers do
  @moduledoc """
  Provides invoice-level formatting utilities intended to be shared across
  billing modules via `use`.
  """

  defmacro __using__(_opts) do
    quote do
      import Billing.CurrencyUtils  # propagates dependency into every caller

      def format_invoice_number(id) when is_integer(id) do
        "INV-#{String.pad_leading(to_string(id), 6, "0")}"
      end

      def format_line_item(description, quantity, unit_price_cents) do
        total = quantity * unit_price_cents
        "  #{description} x#{quantity} @ #{format_currency(unit_price_cents)} = #{format_currency(total)}"
      end

      def format_tax_line(subtotal_cents, rate) do
        tax = round(subtotal_cents * rate)
        "  Tax (#{Float.round(rate * 100, 1)}%): #{format_currency(tax)}"
      end

      def format_total_line(total_cents) do
        "  TOTAL: #{format_currency(total_cents)}"
      end
    end
  end
end

defmodule Billing.InvoiceProcessor do
  @moduledoc """
  Handles invoice creation, line-item calculation, tax computation, and
  plain-text rendering for the billing subsystem.
  """

  # VALIDATION: SMELL START - "Use" instead of "import"
  # VALIDATION: This is a smell because `use Billing.FormatHelpers` triggers
  # VALIDATION: `__using__/1`, which injects an `import Billing.CurrencyUtils`
  # VALIDATION: into this module without the reader being aware of it. The module
  # VALIDATION: only needs the formatting functions defined in `FormatHelpers`;
  # VALIDATION: `import Billing.FormatHelpers` would suffice and would keep
  # VALIDATION: dependencies explicit and readable.
  use Billing.FormatHelpers
  # VALIDATION: SMELL END

  @tax_rate 0.08
  @default_due_days 30

  def process(params) do
    with {:ok, invoice} <- build(params),
         {:ok, invoice} <- validate(invoice),
         {:ok, invoice} <- calculate_totals(invoice) do
      {:ok, invoice}
    end
  end

  def build(params) do
    invoice = %{
      id:            params[:id] || next_id(),
      customer_id:   params.customer_id,
      customer_name: params.customer_name,
      line_items:    params[:line_items] || [],
      issued_at:     DateTime.utc_now(),
      due_at:        due_date(@default_due_days),
      status:        :draft,
      subtotal:      0,
      tax:           0,
      total:         0
    }

    {:ok, invoice}
  end

  def calculate_totals(%{line_items: items} = invoice) do
    subtotal =
      Enum.reduce(items, 0, fn item, acc ->
        acc + item.quantity * item.unit_price_cents
      end)

    tax   = round(subtotal * @tax_rate)
    total = subtotal + tax

    {:ok, %{invoice | subtotal: subtotal, tax: tax, total: total}}
  end

  def render(invoice) do
    header = [
      "Invoice: #{format_invoice_number(invoice.id)}",
      "Customer: #{invoice.customer_name}",
      "Issued:   #{Date.to_iso8601(DateTime.to_date(invoice.issued_at))}",
      "Due:      #{Date.to_iso8601(DateTime.to_date(invoice.due_at))}",
      String.duplicate("-", 48)
    ]

    item_lines =
      Enum.map(invoice.line_items, fn item ->
        format_line_item(item.description, item.quantity, item.unit_price_cents)
      end)

    footer = [
      format_tax_line(invoice.subtotal, @tax_rate),
      format_total_line(invoice.total)
    ]

    (header ++ item_lines ++ footer)
    |> Enum.join("\n")
  end

  def mark_sent(%{status: :draft} = invoice) do
    {:ok, %{invoice | status: :sent}}
  end

  def mark_sent(_invoice), do: {:error, :invalid_state_transition}

  defp validate(%{customer_id: nil}), do: {:error, :missing_customer_id}
  defp validate(%{line_items: []}),   do: {:error, :empty_invoice}
  defp validate(invoice),             do: {:ok, invoice}

  defp next_id, do: :erlang.unique_integer([:positive, :monotonic])

  defp due_date(days) do
    DateTime.add(DateTime.utc_now(), days * 86_400, :second)
  end
end
```
