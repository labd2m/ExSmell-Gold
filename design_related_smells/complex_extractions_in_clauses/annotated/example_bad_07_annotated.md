# Annotated Example 07 — Complex Extractions in Clauses

## Metadata

| Field                  | Value                                                                                              |
|------------------------|----------------------------------------------------------------------------------------------------|
| **Smell name**         | Complex extractions in clauses                                                                     |
| **Expected location**  | `Payments.TransactionHandler.handle/1`                                                             |
| **Affected function**  | `handle/1`                                                                                         |
| **Short explanation**  | The clause dispatch logic relies only on `status` (atom matching) and `amount_cents` (guard comparison), yet the function head in every clause also destructures `transaction_id`, `merchant_id`, `currency`, `payment_method`, and `metadata` — all of which are only used inside the body. With four clauses and seven extractions each, the bodies-only bindings add significant noise to the dispatch-critical ones. |

---

```elixir
defmodule Payments.TransactionHandler do
  @moduledoc """
  Processes incoming payment transactions through fraud checks,
  settlement, refund handling, and chargeback workflows.
  """

  require Logger

  alias Payments.{
    FraudEngine,
    SettlementGateway,
    RefundProcessor,
    ChargebackDesk,
    LedgerWriter,
    AuditLog
  }

  @large_transaction_threshold_cents 1_000_000
  @chargeback_review_threshold_cents 50_000

  # VALIDATION: SMELL START - Complex extractions in clauses
  # VALIDATION: This is a smell because `transaction_id`, `merchant_id`,
  # `currency`, `payment_method`, and `metadata` are extracted in every clause
  # head even though they influence neither which clause is chosen nor any guard.
  # Clause selection is determined entirely by `status`, and the guard uses
  # `amount_cents`. The five body-only bindings clutter each clause signature,
  # making it non-trivial to identify the dispatch mechanism when reading across
  # all four clauses.
  def handle(%Payments.Transaction{
        transaction_id: transaction_id,
        merchant_id: merchant_id,
        currency: currency,
        payment_method: payment_method,
        metadata: metadata,
        status: :authorized,
        amount_cents: amount_cents
      })
      when amount_cents >= @large_transaction_threshold_cents do
    Logger.info(
      "[TransactionHandler] Large authorized transaction #{transaction_id}: " <>
        "#{amount_cents} #{currency} from #{merchant_id}"
    )

    with {:ok, score} <- FraudEngine.score(transaction_id, amount_cents, payment_method, metadata),
         :ok <- validate_fraud_score(score, transaction_id),
         {:ok, _review_id} <- Payments.ManualReviewQueue.submit(transaction_id, score),
         :ok <- LedgerWriter.hold(transaction_id, amount_cents, currency),
         :ok <- AuditLog.write(:large_tx_held, merchant_id, %{
                  transaction_id: transaction_id,
                  amount_cents: amount_cents,
                  fraud_score: score
                }) do
      {:ok, :held_for_review, transaction_id}
    else
      {:error, :fraud_score_too_high} ->
        Logger.warning("[TransactionHandler] High fraud score on #{transaction_id}. Rejecting.")
        LedgerWriter.void(transaction_id)
        {:error, :fraud_rejected}

      {:error, reason} ->
        Logger.error("[TransactionHandler] Large tx #{transaction_id} failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  def handle(%Payments.Transaction{
        transaction_id: transaction_id,
        merchant_id: merchant_id,
        currency: currency,
        payment_method: payment_method,
        metadata: metadata,
        status: :authorized,
        amount_cents: amount_cents
      })
      when amount_cents < @large_transaction_threshold_cents do
    Logger.debug("[TransactionHandler] Settling authorized transaction #{transaction_id}")

    with {:ok, score} <- FraudEngine.score(transaction_id, amount_cents, payment_method, metadata),
         :ok <- validate_fraud_score(score, transaction_id),
         {:ok, settlement_ref} <- SettlementGateway.settle(transaction_id, amount_cents, currency),
         :ok <- LedgerWriter.post(transaction_id, amount_cents, currency, :credit, merchant_id),
         :ok <- AuditLog.write(:tx_settled, merchant_id, %{
                  transaction_id: transaction_id,
                  settlement_ref: settlement_ref,
                  amount_cents: amount_cents
                }) do
      {:ok, :settled, settlement_ref}
    else
      {:error, :fraud_score_too_high} ->
        LedgerWriter.void(transaction_id)
        {:error, :fraud_rejected}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def handle(%Payments.Transaction{
        transaction_id: transaction_id,
        merchant_id: merchant_id,
        currency: currency,
        payment_method: _payment_method,
        metadata: metadata,
        status: :refund_requested,
        amount_cents: amount_cents
      })
      when amount_cents > 0 do
    Logger.info("[TransactionHandler] Processing refund for transaction #{transaction_id}")

    original_tx_id = Map.fetch!(metadata, :original_transaction_id)
    refund_reason = Map.get(metadata, :reason, :unspecified)

    with {:ok, original} <- LedgerWriter.fetch(original_tx_id),
         :ok <- validate_refundable(original, amount_cents),
         {:ok, refund_ref} <- RefundProcessor.issue(transaction_id, amount_cents, currency),
         :ok <- LedgerWriter.post(transaction_id, amount_cents, currency, :debit, merchant_id),
         :ok <- AuditLog.write(:refund_issued, merchant_id, %{
                  transaction_id: transaction_id,
                  original_tx_id: original_tx_id,
                  refund_ref: refund_ref,
                  reason: refund_reason
                }) do
      {:ok, :refunded, refund_ref}
    else
      {:error, :not_refundable} ->
        Logger.warning("[TransactionHandler] Refund denied for #{transaction_id}: not refundable")
        {:error, :not_refundable}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def handle(%Payments.Transaction{
        transaction_id: transaction_id,
        merchant_id: merchant_id,
        currency: currency,
        payment_method: _payment_method,
        metadata: metadata,
        status: :chargeback,
        amount_cents: amount_cents
      })
      when amount_cents >= @chargeback_review_threshold_cents do
    Logger.warning(
      "[TransactionHandler] High-value chargeback #{transaction_id}: " <>
        "#{amount_cents} #{currency}"
    )

    dispute_reason = Map.get(metadata, :dispute_reason, :unknown)

    with {:ok, case_id} <- ChargebackDesk.open_case(transaction_id, amount_cents, dispute_reason),
         :ok <- LedgerWriter.reserve_chargeback(transaction_id, amount_cents, currency),
         :ok <- AuditLog.write(:chargeback_opened, merchant_id, %{
                  transaction_id: transaction_id,
                  case_id: case_id,
                  amount_cents: amount_cents
                }) do
      {:ok, :chargeback_case_opened, case_id}
    else
      {:error, reason} ->
        Logger.error("[TransactionHandler] Chargeback handling failed for #{transaction_id}: #{inspect(reason)}")
        {:error, reason}
    end
  end
  # VALIDATION: SMELL END

  def handle(%Payments.Transaction{transaction_id: txid, status: status}) do
    Logger.error("[TransactionHandler] Unhandled transaction status '#{status}' for #{txid}")
    {:error, :unhandled_status}
  end

  # --- Private helpers ---

  defp validate_fraud_score(score, _tx_id) when score < 80, do: :ok
  defp validate_fraud_score(_score, _tx_id), do: {:error, :fraud_score_too_high}

  defp validate_refundable(%{amount_cents: original_amount}, refund_amount)
       when refund_amount <= original_amount,
       do: :ok

  defp validate_refundable(_, _), do: {:error, :not_refundable}
end
```
