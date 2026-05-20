## Smell Metadata

- **Smell name:** Complex extractions in clauses
- **Expected smell location:** `Billing.InvoiceProcessor.process_invoice/1` — all four clauses
- **Affected function(s):** `process_invoice/1`
- **Explanation:** Each clause head destructures eight fields from the invoice map, but only `status` and `amount` are required by the guard expressions. The remaining six bindings — `customer_id`, `currency`, `due_date`, `discount_rate`, `reference`, and `line_items` — are used exclusively inside the function body. Across four clauses with eight identical extractions each, a reader must mentally trace every variable through both the guard and the body to understand which bindings drive clause selection and which ones serve body computations only.

## Code

```elixir
defmodule Billing.InvoiceProcessor do
  alias Billing.{Customer, Mailer, LedgerEntry, AuditLog}
  require Logger

  @overdue_penalty_rate 0.05
  @large_invoice_threshold 10_000.00
  @vip_discount_bonus 0.02

  @doc """
  Processes an invoice through the billing pipeline.

  Selects a processing strategy based on the invoice's `status` and `amount`.
  Applies the appropriate discount or overdue penalty, inserts a ledger entry,
  and dispatches an email notification to the customer.
  """

  # VALIDATION: SMELL START - Complex extractions in clauses
  # VALIDATION: This is a smell because all eight fields are destructured in every clause head,
  # VALIDATION: yet only `status` and `amount` are consumed by the guard expressions. Bindings
  # VALIDATION: such as `customer_id`, `currency`, `due_date`, `discount_rate`, `reference`,
  # VALIDATION: and `line_items` are used exclusively in the function body. With four clauses
  # VALIDATION: each repeating the same eight-field destructuring, a reader cannot quickly
  # VALIDATION: identify which extractions serve the guard and which serve the body.
  def process_invoice(%{
        customer_id: customer_id,
        amount: amount,
        currency: currency,
        status: status,
        due_date: due_date,
        discount_rate: discount_rate,
        reference: reference,
        line_items: line_items
      }) when status == :pending and amount >= @large_invoice_threshold do
    Logger.info("[Billing] Large invoice #{reference} queued for review (customer=#{customer_id})")

    effective_rate = discount_rate + @vip_discount_bonus
    net_amount = Float.round(amount * (1.0 - effective_rate), 2)

    with {:ok, customer} <- Customer.fetch(customer_id),
         :ok <-
           Mailer.send_large_invoice_notice(
             customer.email,
             reference,
             net_amount,
             currency,
             due_date
           ),
         {:ok, entry} <-
           LedgerEntry.insert(%{
             customer_id: customer_id,
             reference: reference,
             gross_amount: amount,
             net_amount: net_amount,
             currency: currency,
             status: :pending_review,
             line_count: length(line_items)
           }) do
      AuditLog.record(:large_invoice_queued, %{reference: reference, entry_id: entry.id})
      {:ok, entry}
    else
      {:error, reason} ->
        Logger.error("[Billing] Failed processing #{reference}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  def process_invoice(%{
        customer_id: customer_id,
        amount: amount,
        currency: currency,
        status: status,
        due_date: due_date,
        discount_rate: discount_rate,
        reference: reference,
        line_items: line_items
      }) when status == :pending and amount < @large_invoice_threshold do
    Logger.info("[Billing] Standard invoice #{reference} processing (customer=#{customer_id})")

    net_amount = Float.round(amount * (1.0 - discount_rate), 2)

    with {:ok, customer} <- Customer.fetch(customer_id),
         :ok <-
           Mailer.send_invoice_notice(
             customer.email,
             reference,
             net_amount,
             currency,
             due_date
           ),
         {:ok, entry} <-
           LedgerEntry.insert(%{
             customer_id: customer_id,
             reference: reference,
             gross_amount: amount,
             net_amount: net_amount,
             currency: currency,
             status: :pending,
             line_count: length(line_items)
           }) do
      AuditLog.record(:invoice_processed, %{reference: reference, entry_id: entry.id})
      {:ok, entry}
    else
      {:error, reason} ->
        Logger.error("[Billing] Failed processing #{reference}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  def process_invoice(%{
        customer_id: customer_id,
        amount: amount,
        currency: currency,
        status: status,
        due_date: due_date,
        discount_rate: discount_rate,
        reference: reference,
        line_items: line_items
      }) when status == :overdue do
    penalty = Float.round(amount * @overdue_penalty_rate, 2)
    total_due = amount + penalty
    waived = Float.round(amount * discount_rate, 2)

    Logger.warning("[Billing] Overdue invoice #{reference} (customer=#{customer_id}, due=#{due_date})")

    with {:ok, customer} <- Customer.fetch(customer_id),
         :ok <-
           Mailer.send_overdue_notice(
             customer.email,
             reference,
             total_due,
             penalty,
             currency,
             due_date
           ),
         {:ok, entry} <-
           LedgerEntry.insert(%{
             customer_id: customer_id,
             reference: reference,
             gross_amount: amount,
             net_amount: total_due,
             penalty: penalty,
             waived_discount: waived,
             currency: currency,
             status: :overdue,
             line_count: length(line_items)
           }) do
      AuditLog.record(:overdue_invoice_flagged, %{reference: reference, entry_id: entry.id})
      {:ok, entry}
    else
      {:error, reason} ->
        Logger.error("[Billing] Overdue processing failed #{reference}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  def process_invoice(%{
        customer_id: customer_id,
        amount: amount,
        currency: currency,
        status: status,
        due_date: due_date,
        discount_rate: discount_rate,
        reference: reference,
        line_items: line_items
      }) when status == :paid do
    Logger.info("[Billing] Invoice #{reference} already settled by customer #{customer_id}")

    AuditLog.record(:invoice_skipped_paid, %{
      reference: reference,
      customer_id: customer_id,
      amount: amount,
      currency: currency,
      due_date: due_date,
      discount_rate: discount_rate,
      line_count: length(line_items)
    })

    {:ok, :already_paid}
  end
  # VALIDATION: SMELL END
end
```
