# Annotated Example — Inappropriate Intimacy

## Metadata

- **Smell name:** Inappropriate Intimacy
- **Expected smell location:** `process_payment/2` in `Billing.InvoiceProcessor`
- **Affected function(s):** `process_payment/2`
- **Short explanation:** `process_payment/2` directly reads internal fields of `PaymentMethod`
  (`status`, `verified`, `token`, `provider`) and `TaxProfile` (`exemption_code`, `country_code`),
  and accesses an internal field of the resolved `Gateway` struct (`endpoint`). Instead of delegating
  decisions such as "is this payment method usable?" or "what tax rate applies?" to the owning
  modules, the function reaches into those modules' data and applies the logic itself, creating
  tight coupling across module boundaries.

## Code

```elixir
defmodule Billing.InvoiceProcessor do
  @moduledoc """
  Handles invoice generation, tax computation, and payment collection
  for end-of-period billing runs.
  """

  require Logger

  alias Billing.{Invoice, InvoiceItem, InvoiceLine}
  alias Accounts.{Customer, PaymentMethod, TaxProfile}
  alias Payments.{Gateway, ChargeRecord}

  @default_currency "USD"
  @late_fee_rate Decimal.new("0.05")

  # --------------------------------------------------------------------------
  # Public API
  # --------------------------------------------------------------------------

  @doc """
  Builds an invoice for the given customer and billing period.
  Does not charge — use `process_payment/2` to collect funds.
  """
  def build_invoice(customer_id, period_start, period_end) do
    with {:ok, items} <- InvoiceItem.fetch_for_period(customer_id, period_start, period_end),
         subtotal     <- sum_items(items),
         invoice      <- new_invoice(customer_id, period_start, period_end, subtotal, items) do
      {:ok, invoice}
    end
  end

  @doc """
  Applies a late-payment fee to an overdue invoice and persists the update.
  """
  def apply_late_fee(%Invoice{status: :overdue} = invoice) do
    fee     = Decimal.mult(invoice.subtotal, @late_fee_rate)
    updated = Map.merge(invoice, %{late_fee: fee, subtotal: Decimal.add(invoice.subtotal, fee)})
    Invoice.persist(updated)
  end

  def apply_late_fee(%Invoice{status: status}),
    do: {:error, "Late fee not applicable to #{status} invoices"}

  @doc """
  Voids an unpaid invoice, recording the reason for the audit trail.
  """
  def void_invoice(%Invoice{status: :pending} = invoice, reason) when is_binary(reason) do
    Invoice.persist(%{invoice | status: :voided, void_reason: reason, voided_at: DateTime.utc_now()})
  end

  def void_invoice(%Invoice{status: status}, _reason),
    do: {:error, "Cannot void invoice in #{status} state"}

  @doc """
  Collects payment for an already-built invoice.
  Determines the customer's active payment method and applicable tax, then
  issues a charge through the appropriate payment gateway.
  """
  def process_payment(%Invoice{} = invoice, %Customer{} = customer) do
    # VALIDATION: SMELL START - Inappropriate Intimacy
    # VALIDATION: This is a smell because process_payment directly inspects internal
    # VALIDATION: fields of PaymentMethod (status, verified, token) and TaxProfile
    # VALIDATION: (exemption_code, country_code), and accesses the internal Gateway
    # VALIDATION: struct field (endpoint) returned by PaymentMethod.resolve_gateway/1.
    # VALIDATION: Rather than delegating "can I charge this method?" to PaymentMethod
    # VALIDATION: and "what rate applies?" to TaxProfile, the function reaches into
    # VALIDATION: their data and applies the rules itself.
    payment_method = Customer.default_payment_method(customer)

    cond do
      payment_method.status != :active ->
        {:error, :payment_method_inactive}

      payment_method.verified != true ->
        {:error, :payment_method_not_verified}

      true ->
        tax_profile = Customer.tax_profile(customer)

        tax_rate =
          if tax_profile.exemption_code != nil do
            Decimal.new(0)
          else
            TaxProfile.rate_for_country(tax_profile.country_code)
          end

        tax_amount = Decimal.mult(invoice.subtotal, tax_rate)
        total_due  = Decimal.add(invoice.subtotal, tax_amount)

        gateway = PaymentMethod.resolve_gateway(payment_method)

        charge_params = %{
          endpoint:    gateway.endpoint,
          token:       payment_method.token,
          amount:      total_due,
          currency:    invoice.currency,
          descriptor:  "INV-#{invoice.id}",
          idempotency: idempotency_key(invoice)
        }

        case Gateway.charge(charge_params) do
          {:ok, %ChargeRecord{id: charge_id}} ->
            Invoice.persist(%{invoice |
              status:     :paid,
              charge_id:  charge_id,
              tax_amount: tax_amount,
              total:      total_due,
              paid_at:    DateTime.utc_now()
            })

          {:error, reason} ->
            Logger.warning("Payment failed for invoice #{invoice.id}: #{inspect(reason)}")
            {:error, reason}
        end
    end
    # VALIDATION: SMELL END
  end

  @doc """
  Returns all overdue invoices for a given customer.
  """
  def list_overdue(customer_id) do
    Invoice.list(customer_id: customer_id, status: :overdue)
  end

  # --------------------------------------------------------------------------
  # Private helpers
  # --------------------------------------------------------------------------

  defp sum_items(items) do
    Enum.reduce(items, Decimal.new(0), fn %InvoiceLine{amount: a}, acc ->
      Decimal.add(acc, a)
    end)
  end

  defp new_invoice(customer_id, period_start, period_end, subtotal, items) do
    %Invoice{
      customer_id:  customer_id,
      period_start: period_start,
      period_end:   period_end,
      subtotal:     subtotal,
      currency:     @default_currency,
      items:        items,
      status:       :pending,
      issued_at:    DateTime.utc_now()
    }
  end

  defp idempotency_key(%Invoice{id: id, issued_at: issued_at}) do
    :crypto.hash(:sha256, "#{id}-#{issued_at}") |> Base.encode16(case: :lower)
  end
end
```
