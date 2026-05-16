# example_bad_6_clean

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
