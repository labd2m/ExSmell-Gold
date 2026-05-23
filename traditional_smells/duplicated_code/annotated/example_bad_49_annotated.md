# Annotated Example — Duplicated Code

| Field | Value |
|---|---|
| **Smell name** | Duplicated Code |
| **Expected smell location** | `Invoicing.CollectionsService.send_overdue_notice/1` and `Invoicing.CollectionsService.apply_late_fees/1` |
| **Affected functions** | `send_overdue_notice/1`, `apply_late_fees/1` |
| **Short explanation** | Both functions independently compute the late fee amount (days overdue, tiered rate lookup, interest cap check). A change to the late-fee schedule or the cap threshold requires edits in two separate code paths. |

```elixir
defmodule Invoicing.CollectionsService do
  @moduledoc """
  Manages overdue invoice collections, including late-fee calculation and
  automated dunning notices.
  """

  alias Invoicing.{Invoice, LateFee, Customer, Mailer, Repo, AuditLog}

  # Late fee rate schedule keyed by days overdue bands
  @late_fee_rates [
    {1..14,   0.015},
    {15..29,  0.025},
    {30..59,  0.035},
    {60..89,  0.050},
    {90..999, 0.075}
  ]
  @max_late_fee_pct 0.15

  # ---------------------------------------------------------------------------
  # Dunning notice
  # ---------------------------------------------------------------------------

  @doc """
  Sends an overdue notice to the customer, including the projected late fee
  if the invoice is not settled within 5 business days.
  """
  def send_overdue_notice(%Invoice{} = invoice) do
    with {:ok, customer} <- Repo.fetch_customer(invoice.customer_id),
         :ok             <- check_invoice_overdue(invoice) do

      # VALIDATION: SMELL START - Duplicated Code
      # VALIDATION: This is a smell because the late-fee computation
      # (days_overdue, rate lookup, interest capping) is copy-pasted
      # verbatim into apply_late_fees/1. A change to the rate schedule
      # must be made in both functions.
      days_overdue = Date.diff(Date.utc_today(), invoice.due_date)

      rate =
        Enum.find_value(@late_fee_rates, 0.015, fn {range, r} ->
          if days_overdue in range, do: r
        end)

      raw_fee = Float.round(invoice.amount_cents * rate / 100, 2)
      max_fee = Float.round(invoice.amount_cents * @max_late_fee_pct / 100, 2)
      late_fee_cents = round(min(raw_fee, max_fee) * 100)
      # VALIDATION: SMELL END

      Mailer.send_overdue_notice(customer, invoice, %{
        days_overdue:      days_overdue,
        projected_fee:     late_fee_cents,
        settlement_window: 5
      })

      AuditLog.log(:overdue_notice_sent, %{
        invoice_id:   invoice.id,
        customer_id:  customer.id,
        days_overdue: days_overdue
      })

      :ok
    end
  end

  # ---------------------------------------------------------------------------
  # Apply late fees
  # ---------------------------------------------------------------------------

  @doc """
  Calculates and applies the late fee to the invoice as a separate line item.
  Returns `{:ok, updated_invoice}` or `{:error, reason}`.
  """
  def apply_late_fees(%Invoice{} = invoice) do
    with {:ok, _customer} <- Repo.fetch_customer(invoice.customer_id),
         :ok              <- check_invoice_overdue(invoice),
         :ok              <- check_fee_not_already_applied(invoice) do

      # VALIDATION: SMELL START - Duplicated Code
      # VALIDATION: This is a smell because the identical late-fee
      # calculation block from send_overdue_notice/1 is reproduced here.
      # The two copies must always agree on rates, rounding, and the cap.
      days_overdue = Date.diff(Date.utc_today(), invoice.due_date)

      rate =
        Enum.find_value(@late_fee_rates, 0.015, fn {range, r} ->
          if days_overdue in range, do: r
        end)

      raw_fee = Float.round(invoice.amount_cents * rate / 100, 2)
      max_fee = Float.round(invoice.amount_cents * @max_late_fee_pct / 100, 2)
      late_fee_cents = round(min(raw_fee, max_fee) * 100)
      # VALIDATION: SMELL END

      fee_record = %LateFee{
        invoice_id:   invoice.id,
        amount_cents: late_fee_cents,
        days_overdue: days_overdue,
        rate_applied: rate,
        applied_at:   DateTime.utc_now()
      }

      case Repo.insert(fee_record) do
        {:ok, _fee} ->
          new_total = invoice.amount_cents + late_fee_cents
          {:ok, updated} = Repo.update(invoice, %{total_with_fees_cents: new_total})
          AuditLog.log(:late_fee_applied, %{
            invoice_id:    invoice.id,
            fee_cents:     late_fee_cents,
            days_overdue:  days_overdue
          })
          {:ok, updated}

        {:error, reason} ->
          {:error, {:db_error, reason}}
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp check_invoice_overdue(%Invoice{due_date: due}) do
    if Date.compare(Date.utc_today(), due) == :gt, do: :ok, else: {:error, :not_overdue}
  end

  defp check_fee_not_already_applied(%Invoice{id: id}) do
    if Repo.late_fee_exists?(id), do: {:error, :fee_already_applied}, else: :ok
  end
end
```
