```elixir
defmodule InvoiceCompiler do
  @moduledoc """
  Assembles a finalised invoice from a billing period's line items.
  Applies tax, validates currency consistency, and numbers the invoice.
  """

  defmodule EmptyInvoiceError do
    defexception [:message, :account_id]
  end

  defmodule UnknownTaxCodeError do
    defexception [:message, :tax_code, :line_item_index]
  end

  defmodule CurrencyMismatchError do
    defexception [:message, :expected_currency, :found_currency, :line_item_index]
  end

  defmodule NegativeSubtotalError do
    defexception [:message, :subtotal_cents]
  end

  @tax_rates %{
    "VAT_20" => 0.20,
    "VAT_5" => 0.05,
    "GST_15" => 0.15,
    "EXEMPT" => 0.00
  }

  def compile(account_id, line_items) when line_items == [] or is_nil(line_items) do
    raise EmptyInvoiceError,
      message: "Cannot compile an invoice with no line items for account #{account_id}",
      account_id: account_id
  end

  def compile(account_id, line_items) do
    base_currency = hd(line_items).currency

    validated_items =
      line_items
      |> Enum.with_index()
      |> Enum.map(fn {item, idx} ->
        if item.currency != base_currency do
          raise CurrencyMismatchError,
            message:
              "Line item #{idx} has currency #{item.currency}; expected #{base_currency}",
            expected_currency: base_currency,
            found_currency: item.currency,
            line_item_index: idx
        end

        tax_rate = Map.get(@tax_rates, item.tax_code)

        if is_nil(tax_rate) do
          raise UnknownTaxCodeError,
            message: "Tax code '#{item.tax_code}' is not recognised at line item #{idx}",
            tax_code: item.tax_code,
            line_item_index: idx
        end

        Map.put(item, :tax_amount_cents, trunc(item.unit_price_cents * item.quantity * tax_rate))
      end)

    subtotal_cents =
      Enum.reduce(validated_items, 0, fn item, acc ->
        acc + item.unit_price_cents * item.quantity
      end)

    if subtotal_cents < 0 do
      raise NegativeSubtotalError,
        message: "Invoice subtotal is negative (#{subtotal_cents}¢); credits may not exceed charges",
        subtotal_cents: subtotal_cents
    end

    tax_total_cents = Enum.sum(Enum.map(validated_items, & &1.tax_amount_cents))

    %{
      invoice_number: next_invoice_number(),
      account_id: account_id,
      currency: base_currency,
      line_items: validated_items,
      subtotal_cents: subtotal_cents,
      tax_cents: tax_total_cents,
      total_cents: subtotal_cents + tax_total_cents,
      compiled_at: DateTime.utc_now(),
      due_date: Date.add(Date.utc_today(), 30)
    }
  end

  defp next_invoice_number do
    "INV-#{Date.utc_today() |> Date.to_string() |> String.replace("-", "")}-#{System.unique_integer([:positive, :monotonic])}"
  end
end

defmodule BillingCycle do
  @moduledoc """
  Closes monthly billing cycles by compiling and dispatching invoices.
  """

  require Logger

  def close(%{account_id: account_id, period_end: period_end, line_items: line_items}) do
    Logger.info("Closing billing cycle for account #{account_id} ending #{period_end}")

    # may have zero usage (empty line items) or configuration issues like bad
    # tax codes — all of which are expected and need structured handling.
    # The client must use try...rescue because InvoiceCompiler offers no
    # tuple-based alternative.
    try do
      invoice = InvoiceCompiler.compile(account_id, line_items)

      Logger.info(
        "Invoice #{invoice.invoice_number} compiled: #{invoice.total_cents}¢ #{invoice.currency}"
      )

      {:ok, invoice}
    rescue
      e in InvoiceCompiler.EmptyInvoiceError ->
        Logger.info("Account #{e.account_id} has no billable items this period; skipping")
        {:skip, :no_billable_items}

      e in InvoiceCompiler.UnknownTaxCodeError ->
        Logger.error(
          "Bad tax code '#{e.tax_code}' at item #{e.line_item_index} for account #{account_id}"
        )
        {:error, {:bad_tax_code, e.tax_code, e.line_item_index}}

      e in InvoiceCompiler.CurrencyMismatchError ->
        Logger.error(
          "Currency mismatch at item #{e.line_item_index}: #{e.found_currency} vs #{e.expected_currency}"
        )
        {:error, {:currency_mismatch, e.expected_currency, e.found_currency}}

      e in InvoiceCompiler.NegativeSubtotalError ->
        Logger.error("Negative subtotal #{e.subtotal_cents}¢ for account #{account_id}")
        {:error, {:negative_subtotal, e.subtotal_cents}}
    end
  end
end
```
