# Annotated Example — Speculative Generality

## Metadata

- **Smell name:** Speculative Generality
- **Expected smell location:** `Billing.CreditNoteProcessor` module
- **Affected function(s):** entire `Billing.CreditNoteProcessor` module
- **Short explanation:** `Billing.CreditNoteProcessor` was created speculatively to handle credit notes when a refund needs to be issued against a closed invoice. The module is fully implemented but is never referenced in `Billing.RefundHandler` or anywhere else in the codebase. All refund flows apply adjustments directly on the original invoice without ever generating a credit note.

---

```elixir
defmodule Billing.RefundHandler do
  @moduledoc """
  Processes customer refund requests against paid invoices.
  Validates eligibility, computes refund amounts, and records
  ledger adjustments.
  """

  alias Billing.{Invoice, LedgerEntry, NotificationMailer}

  require Logger

  @refund_window_days 30

  @spec process(String.t(), float(), String.t()) ::
          {:ok, map()} | {:error, atom()}
  def process(invoice_id, amount, reason) do
    with {:ok, invoice} <- Invoice.fetch(invoice_id),
         :ok <- validate_refundable(invoice),
         :ok <- validate_amount(invoice, amount),
         {:ok, entry} <- LedgerEntry.record_refund(invoice, amount, reason),
         {:ok, updated_invoice} <- Invoice.mark_refunded(invoice, amount),
         :ok <- NotificationMailer.send_refund_confirmation(updated_invoice, amount) do
      Logger.info("Refund processed invoice=#{invoice_id} amount=#{amount}")
      {:ok, %{invoice_id: invoice_id, refund_amount: amount, ledger_entry_id: entry.id}}
    end
  end

  defp validate_refundable(%Invoice{status: :paid, paid_at: paid_at}) do
    cutoff = DateTime.add(DateTime.utc_now(), -@refund_window_days * 86_400, :second)

    if DateTime.compare(paid_at, cutoff) == :gt do
      :ok
    else
      {:error, :refund_window_expired}
    end
  end

  defp validate_refundable(_invoice), do: {:error, :not_refundable}

  defp validate_amount(%Invoice{total: total, refunded_amount: already}, requested)
       when requested > 0 and requested <= total - already do
    :ok
  end

  defp validate_amount(_invoice, _amount), do: {:error, :invalid_refund_amount}
end

# VALIDATION: SMELL START - Speculative Generality
# VALIDATION: This is a smell because `Billing.CreditNoteProcessor` is a fully 
# implemented module that is never called by `Billing.RefundHandler` or any other 
# module in the codebase. It was written speculatively to support generating formal 
# credit note documents against closed invoices, a feature that was planned but 
# never integrated. The module constitutes dead speculative code.
defmodule Billing.CreditNoteProcessor do
  @moduledoc """
  Generates and manages credit notes issued against closed invoices.

  A credit note is a formal accounting document that records a reduction in
  the amount owed by a customer. Credit notes can be applied against future
  invoices or paid out as cash refunds.
  """

  alias Billing.{Invoice, CreditNote, LedgerEntry, PdfRenderer}

  @credit_note_prefix "CN"

  @spec issue(String.t(), float(), String.t()) ::
          {:ok, CreditNote.t()} | {:error, atom()}
  def issue(invoice_id, amount, reason) do
    with {:ok, invoice} <- Invoice.fetch(invoice_id),
         :ok <- validate_credit_eligibility(invoice),
         {:ok, credit_note} <- create_credit_note(invoice, amount, reason),
         :ok <- LedgerEntry.record_credit(invoice, credit_note),
         {:ok, _pdf_path} <- PdfRenderer.render_credit_note(credit_note) do
      {:ok, credit_note}
    end
  end

  @spec apply_to_invoice(String.t(), String.t()) ::
          {:ok, Invoice.t()} | {:error, atom()}
  def apply_to_invoice(credit_note_id, target_invoice_id) do
    with {:ok, credit_note} <- CreditNote.fetch(credit_note_id),
         {:ok, target} <- Invoice.fetch(target_invoice_id),
         :ok <- validate_applicable(credit_note, target),
         {:ok, updated} <- Invoice.apply_credit(target, credit_note.remaining_amount) do
      CreditNote.mark_applied(credit_note, updated.id)
      {:ok, updated}
    end
  end

  defp create_credit_note(invoice, amount, reason) do
    number = "#{@credit_note_prefix}-#{invoice.number}-#{System.unique_integer([:positive])}"

    CreditNote.create(%{
      number: number,
      invoice_id: invoice.id,
      customer_id: invoice.customer_id,
      amount: amount,
      remaining_amount: amount,
      reason: reason,
      issued_at: DateTime.utc_now()
    })
  end

  defp validate_credit_eligibility(%Invoice{status: status}) when status in [:paid, :closed],
    do: :ok

  defp validate_credit_eligibility(_), do: {:error, :invoice_not_eligible}

  defp validate_applicable(%{remaining_amount: rem}, _target) when rem > 0, do: :ok
  defp validate_applicable(_cn, _target), do: {:error, :credit_note_exhausted}
end
# VALIDATION: SMELL END
```
