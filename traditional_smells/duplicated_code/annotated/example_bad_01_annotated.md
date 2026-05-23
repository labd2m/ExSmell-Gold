# Annotated Example – Duplicated Code

| Field | Value |
|---|---|
| **Smell name** | Duplicated Code |
| **Expected smell location** | `BillingInvoice.apply_late_fee/1` and `BillingInvoice.apply_early_payment_discount/1` |
| **Affected functions** | `apply_late_fee/1`, `apply_early_payment_discount/1` |
| **Short explanation** | Both functions independently replicate the same logic to compute the number of days between the invoice due date and today, using identical expressions. If the date-diff logic ever needs to change (e.g., timezone handling), it must be updated in two places, risking divergence. |

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
    # VALIDATION: SMELL START - Duplicated Code
    # VALIDATION: This is a smell because the expression to compute days_overdue
    # (using Date.utc_today, invoice.due_date, and Date.diff) is identical to
    # the one used in apply_early_payment_discount/1 below. Any change to how
    # the day difference is computed must be made in both functions.
    today = Date.utc_today()
    days_overdue = Date.diff(today, invoice.due_date)
    # VALIDATION: SMELL END

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
    # VALIDATION: SMELL START - Duplicated Code
    # VALIDATION: This is a smell because the expression to compute days_until_due
    # mirrors the Date.diff logic already written in apply_late_fee/1.
    today = Date.utc_today()
    days_until_due = Date.diff(invoice.due_date, today)
    # VALIDATION: SMELL END

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
