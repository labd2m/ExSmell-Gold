```elixir
defmodule Billing.Formatter do
  @moduledoc """
  Provides formatting utilities for billing-related identifiers and amounts.
  Used throughout the invoicing pipeline when preparing data for PDF generation,
  email delivery, and audit logs.
  """

  @invoice_prefix "INV"
  @credit_note_prefix "CN"
  @default_currency "BRL"

  @doc """
  Formats a raw invoice number into the canonical display reference used
  on customer-facing documents and in the ERP integration layer.

  ## Examples

      iex> Billing.Formatter.format_invoice_reference(10042)
      "INV-10042"

      iex> Billing.Formatter.format_invoice_reference("10042")
      "INV-10042"

      iex> Billing.Formatter.format_invoice_reference(:draft)
      "INV-draft"
  """

  def format_invoice_reference(raw) do
    "#{@invoice_prefix}-#{to_string(raw)}"
  end

  @doc """
  Formats a credit-note number into its canonical display reference.
  """
  def format_credit_note_reference(number) when is_integer(number) do
    "#{@credit_note_prefix}-#{number}"
  end

  @doc """
  Formats a monetary amount with its currency symbol for display.
  Accepts a numeric value and an optional currency code.
  """
  def format_amount(amount, currency \\ @default_currency)

  def format_amount(amount, currency)
      when is_number(amount) and is_binary(currency) do
    formatted =
      amount
      |> Decimal.from_float()
      |> Decimal.round(2)
      |> Decimal.to_string(:normal)

    "#{currency} #{formatted}"
  rescue
    _ -> "#{currency} #{:erlang.float_to_binary(amount / 1, decimals: 2)}"
  end

  @doc """
  Builds the line-item description shown on an invoice PDF.
  """
  def format_line_item(%{description: desc, quantity: qty, unit_price: price}) do
    "#{qty}x #{desc} @ #{format_amount(price)}"
  end

  @doc """
  Returns the due-date label for a given payment term in days.
  """
  def format_payment_term(days) when is_integer(days) and days >= 0 do
    case days do
      0 -> "Due immediately"
      7 -> "Net 7"
      15 -> "Net 15"
      30 -> "Net 30"
      45 -> "Net 45"
      60 -> "Net 60"
      _ -> "Net #{days}"
    end
  end

  @doc """
  Normalizes a billing period tuple to a human-readable label.
  """
  def format_billing_period({year, month})
      when is_integer(year) and is_integer(month) and month in 1..12 do
    month_name =
      ~w(January February March April May June
         July August September October November December)
      |> Enum.at(month - 1)

    "#{month_name} #{year}"
  end

  @doc """
  Generates a batch export filename for a set of invoices.
  """
  def export_filename(account_id, %Date{} = date) when is_binary(account_id) do
    date_str = Date.to_iso8601(date)
    "invoices_#{account_id}_#{date_str}.csv"
  end

  @doc """
  Constructs the full audit trail label for an invoice event.
  """
  def audit_label(event_type, invoice_ref) when is_atom(event_type) and is_binary(invoice_ref) do
    timestamp = DateTime.utc_now() |> DateTime.to_iso8601()
    "[#{timestamp}] #{event_type} :: #{invoice_ref}"
  end

  @doc """
  Returns a short status badge string for use in UI components.
  """
  def status_badge(:paid), do: "✓ Paid"
  def status_badge(:pending), do: "⏳ Pending"
  def status_badge(:overdue), do: "⚠ Overdue"
  def status_badge(:void), do: "✗ Void"
  def status_badge(:draft), do: "✎ Draft"
end
```
