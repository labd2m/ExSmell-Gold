## Metadata

- **Smell name**: Complex extractions in clauses
- **Expected smell location**: `process_invoice/1`, all three clauses
- **Affected function(s)**: `process_invoice/1`
- **Short explanation**: Each clause of `process_invoice/1` extracts `id`, `customer_id`, `currency`, `due_date`, and `line_items` from the `%Invoice{}` struct solely for use inside the function body. Only `status` and `amount` participate in the guard expressions. Across three clauses with this repeated full extraction, it becomes difficult to distinguish which bindings are structurally meaningful for clause dispatch versus which are just local variables needed for computation.

```elixir
defmodule Billing.InvoiceProcessor do
  alias Billing.{Invoice, Customer, Ledger, Notifier}
  require Logger

  @moduledoc """
  Handles invoice processing for the billing subsystem.
  Supports pending, overdue, and disputed invoice states.
  """

  @late_fee_rate 0.05
  @dispute_hold_days 14

  # VALIDATION: SMELL START - Complex extractions in clauses
  # VALIDATION: This is a smell because `id`, `customer_id`, `currency`, `due_date`, and
  # VALIDATION: `line_items` are extracted in the clause head purely for body usage. Only
  # VALIDATION: `status` and `amount` appear in guards. Repeating all extractions across
  # VALIDATION: three clauses blurs the distinction between guard-relevant and body-only bindings.
  def process_invoice(%Invoice{
        id: id,
        customer_id: customer_id,
        amount: amount,
        currency: currency,
        status: status,
        due_date: due_date,
        line_items: line_items
      }) when status == :pending and amount > 0 do
    Logger.info("Processing pending invoice #{id} for customer #{customer_id}")
    customer = Customer.get!(customer_id)
    formatted = format_amount(amount, currency)
    items_summary = summarize_line_items(line_items)

    case Ledger.record_charge(customer_id, amount, currency) do
      {:ok, transaction_id} ->
        Notifier.send_invoice_receipt(customer.email, %{
          invoice_id: id,
          amount: formatted,
          due_date: due_date,
          items: items_summary,
          transaction_id: transaction_id
        })

        {:ok, transaction_id}

      {:error, reason} ->
        Logger.error("Failed to record charge for invoice #{id}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  def process_invoice(%Invoice{
        id: id,
        customer_id: customer_id,
        amount: amount,
        currency: currency,
        status: status,
        due_date: due_date,
        line_items: line_items
      }) when status == :overdue do
    Logger.warn("Processing overdue invoice #{id} for customer #{customer_id}")
    customer = Customer.get!(customer_id)
    late_fee = Float.round(amount * @late_fee_rate, 2)
    total_due = amount + late_fee

    case Ledger.record_charge(customer_id, total_due, currency) do
      {:ok, transaction_id} ->
        Notifier.send_overdue_notice(customer.email, %{
          invoice_id: id,
          original_amount: format_amount(amount, currency),
          late_fee: format_amount(late_fee, currency),
          total_due: format_amount(total_due, currency),
          due_date: due_date,
          items: summarize_line_items(line_items)
        })

        {:ok, transaction_id}

      {:error, reason} ->
        Logger.error("Failed to process overdue invoice #{id}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  def process_invoice(%Invoice{
        id: id,
        customer_id: customer_id,
        amount: amount,
        currency: currency,
        status: status,
        due_date: due_date,
        line_items: line_items
      }) when status == :disputed do
    Logger.warn("Invoice #{id} for customer #{customer_id} is under dispute")
    hold_until = Date.add(due_date, @dispute_hold_days)
    customer = Customer.get!(customer_id)

    Notifier.send_dispute_acknowledgment(customer.email, %{
      invoice_id: id,
      amount: format_amount(amount, currency),
      currency: currency,
      items: summarize_line_items(line_items),
      hold_until: hold_until
    })

    {:ok, :dispute_acknowledged}
  end
  # VALIDATION: SMELL END

  defp format_amount(amount, currency) do
    "#{currency} #{:erlang.float_to_binary(amount / 1, decimals: 2)}"
  end

  defp summarize_line_items(items) do
    Enum.map(items, fn %{description: desc, quantity: qty, unit_price: price} ->
      "#{qty}x #{desc} @ #{price}"
    end)
  end
end
```
