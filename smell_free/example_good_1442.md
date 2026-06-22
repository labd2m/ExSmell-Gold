```elixir
defmodule MyApp.Billing.ProFormaInvoiceBuilder do
  @moduledoc """
  Generates pro-forma invoice drafts for customer approval before a
  subscription upgrade or large order is finalised. Pro-forma invoices
  are read-only projections that mirror the structure of a live invoice
  without being assigned an invoice number or affecting any ledger.

  The builder accepts a list of line items and a set of applicable
  discounts and tax rates, computes the full price breakdown, and
  returns a plain data struct that can be serialised to PDF or JSON.
  """

  alias MyApp.Billing.{TaxRate, ProFormaInvoice, InvoiceLine}

  @type line_input :: %{
          required(:description) => String.t(),
          required(:quantity) => pos_integer(),
          required(:unit_price_cents) => pos_integer(),
          optional(:discount_bps) => non_neg_integer()
        }

  @doc """
  Builds a `ProFormaInvoice` struct from `lines`, `tax_rates`, and
  an optional header-level `discount_bps` applied after line discounts.
  """
  @spec build([line_input()], [TaxRate.t()], non_neg_integer()) ::
          {:ok, ProFormaInvoice.t()} | {:error, :no_lines}
  def build(lines, tax_rates \\ [], header_discount_bps \\ 0)
      when is_list(lines) and is_list(tax_rates) do
    if lines == [] do
      {:error, :no_lines}
    else
      invoice_lines = Enum.map(lines, &build_line/1)
      lines_subtotal = Enum.sum_by(invoice_lines, & &1.net_cents)
      header_discount_cents = div(lines_subtotal * header_discount_bps, 10_000)
      taxable_subtotal = lines_subtotal - header_discount_cents
      tax_lines = compute_tax_lines(taxable_subtotal, tax_rates)
      total_tax = Enum.sum_by(tax_lines, & &1.net_cents)

      invoice = %ProFormaInvoice{
        lines: invoice_lines,
        header_discount_bps: header_discount_bps,
        header_discount_cents: header_discount_cents,
        lines_subtotal_cents: lines_subtotal,
        taxable_subtotal_cents: taxable_subtotal,
        tax_lines: tax_lines,
        total_tax_cents: total_tax,
        total_cents: taxable_subtotal + total_tax,
        generated_at: DateTime.utc_now()
      }

      {:ok, invoice}
    end
  end

  @spec build_line(line_input()) :: InvoiceLine.t()
  defp build_line(input) do
    gross = input.quantity * input.unit_price_cents
    discount_bps = Map.get(input, :discount_bps, 0)
    discount_cents = div(gross * discount_bps, 10_000)

    %InvoiceLine{
      description: input.description,
      quantity: input.quantity,
      unit_price_cents: input.unit_price_cents,
      gross_cents: gross,
      discount_bps: discount_bps,
      discount_cents: discount_cents,
      net_cents: gross - discount_cents
    }
  end

  @spec compute_tax_lines(non_neg_integer(), [TaxRate.t()]) :: [InvoiceLine.t()]
  defp compute_tax_lines(subtotal, tax_rates) do
    Enum.map(tax_rates, fn rate ->
      tax_cents = round(subtotal * rate.rate_bps / 10_000)

      %InvoiceLine{
        description: "#{rate.label} (#{Float.round(rate.rate_bps / 100.0, 2)}%)",
        quantity: 1,
        unit_price_cents: tax_cents,
        gross_cents: tax_cents,
        discount_bps: 0,
        discount_cents: 0,
        net_cents: tax_cents
      }
    end)
  end
end
```
