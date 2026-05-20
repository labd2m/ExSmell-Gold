```elixir
defmodule Billing.InvoiceProcessor do
  @moduledoc """
  Processes invoices through the billing pipeline, handling state
  transitions for pending, overdue, paid, and voided invoices.
  """

  require Logger

  alias Billing.{Customer, Invoice, Ledger, Notifier, Repo}

  @high_value_threshold 10_000
  @overdue_penalty_rate 0.015

  def process_batch(invoice_ids) when is_list(invoice_ids) do
    results =
      invoice_ids
      |> Enum.map(&fetch_and_process/1)
      |> Enum.group_by(fn
        {:ok, _} -> :success
        {:error, _} -> :failure
      end)

    success_count = length(Map.get(results, :success, []))
    failure_count = length(Map.get(results, :failure, []))

    Logger.info("[InvoiceProcessor] Batch done: #{success_count} ok, #{failure_count} failed")
    {:ok, %{processed: success_count, errors: failure_count}}
  end

  defp fetch_and_process(invoice_id) do
    case Repo.get(Invoice, invoice_id) do
      nil -> {:error, :not_found}
      invoice -> process_invoice(invoice)
    end
  end

  def process_invoice(%Invoice{
        id: id,
        status: status,
        amount: amount,
        customer_id: customer_id,
        due_date: due_date,
        currency: currency
      })
      when status == :pending and amount > @high_value_threshold do
    Logger.info("[InvoiceProcessor] High-value pending invoice=#{id} customer=#{customer_id}")

    with {:ok, customer} <- Customer.get(customer_id),
         :ok <- assert_credit_available(customer, amount),
         {:ok, _entry} <- Ledger.post_pending(id, amount, currency),
         :ok <- schedule_due_date_reminder(id, due_date) do
      Notifier.notify_high_value_invoice(customer, id, amount, currency)
      {:ok, :pending_review}
    end
  end

  def process_invoice(%Invoice{
        id: id,
        status: status,
        amount: amount,
        customer_id: customer_id,
        due_date: due_date,
        currency: currency
      })
      when status == :pending and amount <= @high_value_threshold do
    Logger.info("[InvoiceProcessor] Standard pending invoice=#{id} customer=#{customer_id}")

    with {:ok, _entry} <- Ledger.post_pending(id, amount, currency),
         :ok <- schedule_due_date_reminder(id, due_date) do
      {:ok, :scheduled}
    end
  end

  def process_invoice(%Invoice{
        id: id,
        status: status,
        amount: amount,
        customer_id: customer_id,
        due_date: due_date,
        currency: currency
      })
      when status == :overdue do
    penalty = Float.round(amount * @overdue_penalty_rate, 2)

    Logger.warning(
      "[InvoiceProcessor] Overdue invoice=#{id} customer=#{customer_id} " <>
        "original=#{amount} penalty=#{penalty} #{currency}"
    )

    with {:ok, customer} <- Customer.get(customer_id),
         {:ok, _entry} <- Ledger.post_penalty(id, penalty, currency),
         :ok <- Notifier.send_overdue_notice(customer, id, amount, penalty, due_date, currency) do
      {:ok, :penalty_applied}
    end
  end

  def process_invoice(%Invoice{
        id: id,
        status: status,
        amount: amount,
        customer_id: customer_id,
        due_date: _due_date,
        currency: currency
      })
      when status == :paid do
    Logger.debug(
      "[InvoiceProcessor] Invoice=#{id} already settled by customer=#{customer_id} " <>
        "amount=#{amount} #{currency}"
    )

    {:ok, :no_op}
  end

  defp assert_credit_available(customer, requested_amount) do
    if customer.available_credit >= requested_amount do
      :ok
    else
      {:error, {:insufficient_credit, customer.id}}
    end
  end

  defp schedule_due_date_reminder(invoice_id, due_date) do
    days_until = Date.diff(due_date, Date.utc_today())

    cond do
      days_until <= 0 -> :ok
      days_until <= 3 -> Notifier.schedule_reminder(invoice_id, :urgent, due_date)
      days_until <= 7 -> Notifier.schedule_reminder(invoice_id, :standard, due_date)
      true -> :ok
    end
  end
end
```
