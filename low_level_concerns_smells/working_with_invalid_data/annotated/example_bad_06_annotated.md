# Code Smell: Working with invalid data

- **Smell name:** Working with invalid data
- **Expected smell location:** `apply_discount/2` function, where `discount_rate` is passed without validation into arithmetic operations and downstream formatters
- **Affected function(s):** `apply_discount/2`, `generate_invoice_line/3`
- **Short explanation:** `apply_discount/2` accepts `discount_rate` from an external map without validating whether it is a number, zero, or within a valid range. The raw value is forwarded directly into arithmetic expressions and a third-party formatter, causing cryptic errors deep in the call stack when invalid data is provided.

```elixir
defmodule Billing.InvoiceProcessor do
  @moduledoc """
  Handles invoice generation, discount application, and PDF rendering
  for subscription-based billing cycles.
  """

  alias Billing.PdfRenderer
  alias Billing.TaxCalculator

  @default_currency "USD"
  @invoice_version "2.1"

  def process_invoice(account_id, line_items, opts \\ []) do
    currency = Keyword.get(opts, :currency, @default_currency)
    due_days = Keyword.get(opts, :due_days, 30)

    with {:ok, account} <- fetch_account(account_id),
         {:ok, enriched_lines} <- enrich_line_items(line_items, account),
         {:ok, totals} <- calculate_totals(enriched_lines, currency),
         {:ok, pdf_path} <- render_invoice(account, enriched_lines, totals, due_days) do
      {:ok, %{account_id: account_id, pdf_path: pdf_path, totals: totals}}
    end
  end

  defp fetch_account(account_id) do
    # Simulated DB lookup
    {:ok, %{id: account_id, name: "Acme Corp", tier: :enterprise, discount_policy: %{rate: nil}}}
  end

  defp enrich_line_items(line_items, account) do
    enriched =
      Enum.map(line_items, fn item ->
        discount_rate = get_in(account, [:discount_policy, :rate])
        generate_invoice_line(item, discount_rate, account.tier)
      end)

    {:ok, enriched}
  end

  # VALIDATION: SMELL START - Working with invalid data
  # VALIDATION: This is a smell because `discount_rate` is taken directly from
  # an external map without any type or range validation. It is passed into
  # `apply_discount/2` and then forwarded to `PdfRenderer.format_currency/2`,
  # which will raise a cryptic internal error if the value is nil, a string,
  # or outside the [0.0, 1.0] range. The developer will see an error deep
  # inside the renderer or arithmetic layer with no clear indication that the
  # root cause is an unvalidated discount_rate at this boundary.
  defp generate_invoice_line(item, discount_rate, tier) do
    base_price = Map.fetch!(item, :unit_price) * Map.fetch!(item, :quantity)
    discounted_price = apply_discount(base_price, discount_rate)
    tax = TaxCalculator.compute(discounted_price, tier)

    %{
      description: Map.fetch!(item, :description),
      quantity: Map.fetch!(item, :quantity),
      unit_price: Map.fetch!(item, :unit_price),
      discount_rate: discount_rate,
      discounted_price: discounted_price,
      tax: tax,
      line_total: discounted_price + tax,
      formatted_total: PdfRenderer.format_currency(discounted_price + tax, @default_currency)
    }
  end

  defp apply_discount(price, discount_rate) do
    price * (1 - discount_rate)
  end
  # VALIDATION: SMELL END

  defp calculate_totals(enriched_lines, currency) do
    subtotal = Enum.reduce(enriched_lines, 0.0, fn line, acc -> acc + line.discounted_price end)
    total_tax = Enum.reduce(enriched_lines, 0.0, fn line, acc -> acc + line.tax end)
    grand_total = subtotal + total_tax

    {:ok,
     %{
       subtotal: subtotal,
       total_tax: total_tax,
       grand_total: grand_total,
       currency: currency
     }}
  end

  defp render_invoice(account, lines, totals, due_days) do
    due_date = Date.add(Date.utc_today(), due_days)

    PdfRenderer.render(%{
      version: @invoice_version,
      account: account,
      lines: lines,
      totals: totals,
      due_date: due_date
    })
  end
end
```
