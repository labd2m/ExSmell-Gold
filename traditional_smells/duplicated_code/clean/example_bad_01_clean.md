```elixir
defmodule Billing.InvoiceAdjustments do
  @moduledoc """
  Handles post-issuance adjustments to invoices, including late fees
  and early-payment discounts.
  """

  alias Billing.Invoice
  alias Billing.Repo

  @late_fee_rate 0.015
  @early_discount_rate 0.02
  @grace_period_days 5
  @early_payment_threshold_days 10

  @doc """
  Applies a late fee to the given invoice if it is past its due date
  beyond the grace period. Returns the updated invoice or an error tuple.
  """
  def apply_late_fee(%Invoice{} = invoice) do
    today = Date.utc_today()
    days_overdue = Date.diff(today, invoice.due_date)

    if days_overdue > @grace_period_days do
      fee = invoice.amount_due * @late_fee_rate * days_overdue
      updated = %{invoice | amount_due: invoice.amount_due + fee, late_fee_applied: true}

      case Repo.update(updated) do
        {:ok, saved} ->
          {:ok, saved}

        {:error, changeset} ->
          {:error, {:db_error, changeset}}
      end
    else
      {:ok, invoice}
    end
  end

  @doc """
  Applies an early-payment discount if the invoice is paid before the
  threshold number of days prior to the due date. Returns the updated
  invoice or an error tuple.
  """
  def apply_early_payment_discount(%Invoice{} = invoice) do
    today = Date.utc_today()
    days_until_due = Date.diff(invoice.due_date, today)

    if days_until_due >= @early_payment_threshold_days do
      discount = invoice.amount_due * @early_discount_rate
      updated = %{invoice | amount_due: invoice.amount_due - discount, discount_applied: true}

      case Repo.update(updated) do
        {:ok, saved} ->
          {:ok, saved}

        {:error, changeset} ->
          {:error, {:db_error, changeset}}
      end
    else
      {:ok, invoice}
    end
  end

  @doc """
  Returns a summary map of all adjustments applied to an invoice.
  """
  def adjustment_summary(%Invoice{} = invoice) do
    %{
      invoice_id: invoice.id,
      original_amount: invoice.original_amount,
      final_amount: invoice.amount_due,
      late_fee_applied: invoice.late_fee_applied,
      discount_applied: invoice.discount_applied,
      net_change: invoice.amount_due - invoice.original_amount
    }
  end

  @doc """
  Voids any pending adjustments on an invoice, resetting it to its
  original amount.
  """
  def void_adjustments(%Invoice{} = invoice) do
    reset = %{
      invoice
      | amount_due: invoice.original_amount,
        late_fee_applied: false,
        discount_applied: false
    }

    Repo.update(reset)
  end
end
```
