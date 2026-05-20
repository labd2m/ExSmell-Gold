# Annotated Example 01 — Complex Extractions in Clauses

## Metadata

| Field                  | Value                                                                 |
|------------------------|-----------------------------------------------------------------------|
| **Smell name**         | Complex extractions in clauses                                        |
| **Expected location**  | `Billing.InvoiceProcessor.process_invoice/1`                          |
| **Affected function**  | `process_invoice/1`                                                   |
| **Short explanation**  | The function head extracts `status` and `due_date` for clause matching/guard use, but also extracts `invoice_id`, `customer_name`, `amount`, and `currency` which are only needed inside the body. With multiple clauses, it becomes hard to distinguish which bindings drive dispatching and which are convenience extractions for the body. |

---

```elixir
defmodule Billing.InvoiceProcessor do
  @moduledoc """
  Handles invoice lifecycle processing including overdue detection,
  payment scheduling, dispute routing, and write-off procedures.
  """

  require Logger

  alias Billing.{Invoice, LedgerEntry, AuditLog, Notifier}

  @late_fee_rate 0.05
  @write_off_threshold_days 180

  # VALIDATION: SMELL START - Complex extractions in clauses
  # VALIDATION: This is a smell because all five fields — `invoice_id`,
  # `customer_name`, `amount`, `currency`, `status`, and `due_date` — are
  # destructured in the function head. However, only `status` is used for
  # clause selection and `due_date` is used in the guard. The remaining fields
  # (`invoice_id`, `customer_name`, `amount`, `currency`) are only consumed
  # inside the body. With three clauses and six extractions, it is difficult to
  # tell at a glance which bindings are controlling dispatch and which are just
  # body-level convenience bindings.
  def process_invoice(%Invoice{
        invoice_id: invoice_id,
        customer_name: customer_name,
        amount: amount,
        currency: currency,
        status: :pending,
        due_date: due_date
      })
      when due_date < ~D[2024-06-01] do
    days_overdue = Date.diff(Date.utc_today(), due_date)
    late_fee = Float.round(amount * @late_fee_rate, 2)

    Logger.warning(
      "[InvoiceProcessor] Overdue invoice #{invoice_id} for #{customer_name} " <>
        "(#{days_overdue} days overdue). Applying late fee of #{late_fee} #{currency}."
    )

    with {:ok, _entry} <- LedgerEntry.record_late_fee(invoice_id, late_fee, currency),
         {:ok, _notif} <- Notifier.send_overdue_notice(customer_name, invoice_id, late_fee),
         {:ok, _log} <- AuditLog.write(:late_fee_applied, invoice_id, %{fee: late_fee}) do
      {:overdue, invoice_id, late_fee}
    else
      {:error, reason} ->
        Logger.error("[InvoiceProcessor] Failed to process overdue invoice #{invoice_id}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  def process_invoice(%Invoice{
        invoice_id: invoice_id,
        customer_name: customer_name,
        amount: amount,
        currency: currency,
        status: :pending,
        due_date: due_date
      })
      when due_date >= ~D[2024-06-01] do
    Logger.info(
      "[InvoiceProcessor] Scheduling payment for invoice #{invoice_id} — " <>
        "#{customer_name}, #{amount} #{currency}, due #{due_date}."
    )

    with {:ok, _sched} <- schedule_payment(invoice_id, amount, currency, due_date),
         {:ok, _notif} <- Notifier.send_payment_reminder(customer_name, invoice_id, due_date),
         {:ok, _log} <- AuditLog.write(:payment_scheduled, invoice_id, %{amount: amount}) do
      {:scheduled, invoice_id}
    else
      {:error, reason} ->
        Logger.error("[InvoiceProcessor] Failed to schedule payment for #{invoice_id}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  def process_invoice(%Invoice{
        invoice_id: invoice_id,
        customer_name: customer_name,
        amount: amount,
        currency: currency,
        status: :disputed,
        due_date: due_date
      })
      when due_date < ~D[2024-01-01] do
    days_open = Date.diff(Date.utc_today(), due_date)

    Logger.warning(
      "[InvoiceProcessor] Long-standing dispute on invoice #{invoice_id} for #{customer_name}. " <>
        "Open for #{days_open} days. Amount: #{amount} #{currency}. Escalating."
    )

    with {:ok, _ticket} <- open_escalation_ticket(invoice_id, customer_name, amount),
         {:ok, _log} <- AuditLog.write(:dispute_escalated, invoice_id, %{days_open: days_open}) do
      {:escalated, invoice_id}
    else
      {:error, reason} ->
        Logger.error("[InvoiceProcessor] Escalation failed for invoice #{invoice_id}: #{inspect(reason)}")
        {:error, reason}
    end
  end
  # VALIDATION: SMELL END

  def process_invoice(%Invoice{invoice_id: invoice_id, status: :paid}) do
    Logger.info("[InvoiceProcessor] Invoice #{invoice_id} already settled. No action needed.")
    {:already_paid, invoice_id}
  end

  def process_invoice(%Invoice{invoice_id: invoice_id, status: unknown_status}) do
    Logger.error("[InvoiceProcessor] Unknown status '#{unknown_status}' on invoice #{invoice_id}.")
    {:error, :unknown_status}
  end

  # --- Private helpers ---

  defp schedule_payment(invoice_id, amount, currency, due_date) do
    Billing.PaymentScheduler.enqueue(%{
      invoice_id: invoice_id,
      amount: amount,
      currency: currency,
      execute_on: due_date
    })
  end

  defp open_escalation_ticket(invoice_id, customer_name, amount) do
    Billing.DisputeDesk.create_ticket(%{
      invoice_id: invoice_id,
      customer: customer_name,
      amount: amount,
      priority: :high
    })
  end
end
```
