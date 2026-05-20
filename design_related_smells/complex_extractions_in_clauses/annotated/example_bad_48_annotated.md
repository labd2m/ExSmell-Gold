## Metadata

- **Smell name:** Complex extractions in clauses
- **Expected smell location:** `Billing.InvoiceProcessor.process_invoice/1`
- **Affected function(s):** `process_invoice/1`
- **Explanation:** Each clause of `process_invoice/1` destructures many fields from the
  `%Invoice{}` struct (`customer_id`, `due_date`, `discount_code`, `tax_rate`, `currency`,
  `notes`) directly in the function head, but only `status` and `amount` are actually
  used in guard expressions. All remaining bindings are referenced solely inside the
  function body. With three clauses and eight extracted fields per head, it becomes very
  hard to distinguish which extractions drive the dispatch logic and which are merely
  convenience bindings for the body.

## Code

```elixir
defmodule Billing.InvoiceProcessor do
  @moduledoc """
  Handles the full lifecycle of customer invoices.
  Supports pending, overdue, and draft states with email notifications and ledger entries.
  """

  alias Billing.{Customer, Ledger, Mailer, AuditLog}
  require Logger

  @overdue_surcharge_rate 0.05

  def run(invoice_id) do
    with {:ok, invoice} <- Ledger.fetch_invoice(invoice_id),
         {:ok, result} <- process_invoice(invoice) do
      AuditLog.record(:invoice_processed, invoice_id, result)
      {:ok, result}
    else
      {:error, :not_found} ->
        Logger.error("Invoice not found: #{invoice_id}")
        {:error, :not_found}

      {:error, reason} ->
        Logger.error("Failed to process invoice #{invoice_id}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  # VALIDATION: SMELL START - Complex extractions in clauses
  # VALIDATION: This is a smell because each clause of process_invoice/1 extracts eight
  # fields from the %Invoice{} struct in the function head (status, amount, customer_id,
  # due_date, discount_code, tax_rate, currency, notes), but only `status` and `amount`
  # are used in guard expressions. The remaining six fields (customer_id, due_date,
  # discount_code, tax_rate, currency, notes) are used exclusively inside the function
  # body. Across three clauses, this creates 24 pattern extractions in function heads
  # that conflate guard-relevant and body-only bindings, significantly impairing
  # readability and making maintenance harder as the function grows.

  def process_invoice(%Invoice{
        status: status,
        amount: amount,
        customer_id: customer_id,
        due_date: due_date,
        discount_code: discount_code,
        tax_rate: tax_rate,
        currency: currency,
        notes: notes
      })
      when status == :pending and amount > 0 do
    customer = Customer.fetch!(customer_id)
    discounted = apply_discount(amount, discount_code)
    total = Float.round(discounted + discounted * tax_rate, 2)

    Mailer.send_invoice_notice(customer.email, %{
      total: total,
      currency: currency,
      due_date: due_date,
      notes: notes
    })

    Ledger.record_pending(customer_id, total, currency)
    {:ok, %{status: :pending_charged, total: total, customer_id: customer_id}}
  end

  def process_invoice(%Invoice{
        status: status,
        amount: amount,
        customer_id: customer_id,
        due_date: due_date,
        discount_code: discount_code,
        tax_rate: tax_rate,
        currency: currency,
        notes: notes
      })
      when status == :overdue and amount > 0 do
    customer = Customer.fetch!(customer_id)
    discounted = apply_discount(amount, discount_code)
    base = Float.round(discounted + discounted * tax_rate, 2)
    surcharge = Float.round(base * @overdue_surcharge_rate, 2)
    total = base + surcharge
    days_late = Date.diff(Date.utc_today(), due_date)

    Mailer.send_overdue_notice(customer.email, %{
      total: total,
      currency: currency,
      days_late: days_late,
      notes: notes
    })

    Ledger.record_overdue(customer_id, total, surcharge, currency)
    {:ok, %{status: :overdue_charged, total: total, surcharge: surcharge, customer_id: customer_id}}
  end

  def process_invoice(%Invoice{
        status: status,
        amount: amount,
        customer_id: customer_id,
        due_date: due_date,
        discount_code: discount_code,
        tax_rate: tax_rate,
        currency: currency,
        notes: notes
      })
      when status == :draft and amount == 0 do
    customer = Customer.fetch!(customer_id)
    preview_base = apply_discount(100.0, discount_code)
    estimated = Float.round(preview_base + preview_base * tax_rate, 2)

    Mailer.send_draft_summary(customer.email, %{
      estimated_total: estimated,
      currency: currency,
      due_date: due_date,
      notes: notes
    })

    Ledger.touch_draft(customer_id, discount_code)
    {:ok, %{status: :draft_summarized, customer_id: customer_id}}
  end

  # VALIDATION: SMELL END

  def process_invoice(%Invoice{status: :paid}) do
    {:ok, :already_paid}
  end

  def process_invoice(%Invoice{status: :cancelled, customer_id: customer_id}) do
    Logger.info("Skipping cancelled invoice for customer=#{customer_id}")
    {:ok, :skipped}
  end

  def process_invoice(%Invoice{status: status}) do
    Logger.warning("Unhandled invoice status: #{inspect(status)}")
    {:error, {:unhandled_status, status}}
  end

  defp apply_discount(amount, nil), do: amount

  defp apply_discount(amount, code) do
    case Ledger.fetch_discount_rate(code) do
      {:ok, rate} when rate > 0 and rate < 1 ->
        Float.round(amount * (1 - rate), 2)

      _ ->
        amount
    end
  end
end
```
