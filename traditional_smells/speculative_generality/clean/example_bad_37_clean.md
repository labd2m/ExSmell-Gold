```elixir
defmodule Billing.AdjustmentService do
  @moduledoc """
  Applies post-issue adjustments to invoices.

  Adjustments may correct line-item errors, apply negotiated discounts
  after the fact, or reflect returns of goods or services. Every
  adjustment is recorded in the ledger and the invoice audit trail.
  """

  alias Billing.{Invoice, LineItem, LedgerEntry, AuditTrail, PdfRenderer}

  require Logger

  @adjustment_types [:correction, :discount, :return, :write_off]

  @spec apply_adjustment(String.t(), map()) :: {:ok, Invoice.t()} | {:error, atom()}
  def apply_adjustment(invoice_id, %{type: type, amount: amount, reason: reason} = adjustment) do
    with :ok <- validate_adjustment_type(type),
         :ok <- validate_amount(amount),
         {:ok, invoice} <- Invoice.fetch(invoice_id),
         :ok <- validate_adjustable(invoice),
         {:ok, updated_invoice} <- Invoice.apply_adjustment(invoice, amount, type),
         {:ok, _entry} <- LedgerEntry.record_adjustment(invoice, adjustment),
         :ok <- AuditTrail.log(invoice_id, :adjustment_applied, adjustment) do
      Logger.info(
        "Adjustment applied invoice=#{invoice_id} type=#{type} amount=#{amount} reason=#{reason}"
      )

      {:ok, updated_invoice}
    else
      {:error, :not_found} ->
        Logger.warning("Adjustment failed: invoice not found id=#{invoice_id}")
        {:error, :not_found}

      {:error, reason} ->
        Logger.error("Adjustment failed invoice=#{invoice_id}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  def generate_credit_memo(invoice_id, overpayment_amount) do
    with {:ok, invoice} <- Invoice.fetch(invoice_id) do
      memo_number = "CM-#{invoice.number}-#{System.unique_integer([:positive])}"

      memo = %{
        number: memo_number,
        invoice_id: invoice_id,
        customer_id: invoice.customer_id,
        amount: overpayment_amount,
        currency: invoice.currency,
        issued_at: DateTime.utc_now(),
        reason: "Overpayment due to post-issue adjustment"
      }

      case PdfRenderer.render(:credit_memo, memo) do
        {:ok, pdf_path} ->
          Logger.info("Credit memo generated number=#{memo_number} path=#{pdf_path}")
          {:ok, Map.put(memo, :pdf_path, pdf_path)}

        {:error, render_err} ->
          Logger.error("Credit memo render failed: #{inspect(render_err)}")
          {:error, :render_failed}
      end
    end
  end

  defp validate_adjustment_type(type) when type in @adjustment_types, do: :ok
  defp validate_adjustment_type(type), do: {:error, {:invalid_type, type}}

  defp validate_amount(amount) when is_float(amount) and amount > 0, do: :ok
  defp validate_amount(amount) when is_integer(amount) and amount > 0, do: :ok
  defp validate_amount(_), do: {:error, :invalid_amount}

  defp validate_adjustable(%Invoice{status: :issued}), do: :ok
  defp validate_adjustable(%Invoice{status: :partially_paid}), do: :ok
  defp validate_adjustable(_invoice), do: {:error, :not_adjustable}
end
```
