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
  end

  @doc """
  Returns all overdue invoices for a given customer.
  """
  def list_overdue(customer_id) do
    Invoice.list(customer_id: customer_id, status: :overdue)
  end


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
