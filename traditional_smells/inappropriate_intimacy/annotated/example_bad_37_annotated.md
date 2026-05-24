# Annotated Example — Inappropriate Intimacy

## Metadata

- **Smell name:** Inappropriate Intimacy
- **Expected smell location:** `process_refund/1` in `Payments.RefundOrchestrator`
- **Affected function(s):** `process_refund/1`
- **Short explanation:** `process_refund/1` reads internal fields of `Transaction`
  (`merchant_id`, `gateway_ref`, `captured_at`), `MerchantPolicy` (`allows_partial_refunds`,
  `refund_hold_days`), and `Settlement` (`status`, `settled_at`, `batch_id`) to compute
  whether and when a refund can be issued. These rules belong to the respective modules;
  the orchestrator should receive a refund-readiness answer, not inspect raw internal data.

## Code

```elixir
defmodule Payments.RefundOrchestrator do
  @moduledoc """
  Orchestrates refund workflows including partial refunds, full reversals,
  and settlement-period hold enforcement.
  """

  require Logger

  alias Payments.{Transaction, Refund, RefundRequest, Settlement}
  alias Merchants.{Merchant, MerchantPolicy}

  @max_refund_days 90
  @partial_refund_min Decimal.new("1.00")

  def request_refund(transaction_id, amount, reason, requester_id) do
    with {:ok, txn} <- Transaction.fetch(transaction_id) do
      cond do
        txn.status not in [:settled, :captured] ->
          {:error, :transaction_not_refundable}

        days_since(txn) > @max_refund_days ->
          {:error, :refund_window_expired}

        Decimal.compare(amount, txn.amount) == :gt ->
          {:error, :amount_exceeds_transaction}

        Decimal.compare(amount, @partial_refund_min) == :lt ->
          {:error, :amount_below_minimum}

        true ->
          RefundRequest.create(%{
            transaction_id: transaction_id,
            amount:         amount,
            reason:         reason,
            requester_id:   requester_id,
            status:         :pending,
            created_at:     DateTime.utc_now()
          })
      end
    end
  end

  def process_refund(%RefundRequest{} = request) do
    # VALIDATION: SMELL START - Inappropriate Intimacy
    # VALIDATION: This is a smell because process_refund directly reads Transaction.merchant_id,
    # VALIDATION: Transaction.gateway_ref, Transaction.captured_at, MerchantPolicy.allows_partial_refunds,
    # VALIDATION: MerchantPolicy.refund_hold_days, Settlement.status, Settlement.settled_at, and
    # VALIDATION: Settlement.batch_id, rather than delegating "is a refund eligible now?" to
    # VALIDATION: MerchantPolicy or Settlement and "how do I charge back?" to Transaction.
    with {:ok, txn} <- Transaction.fetch(request.transaction_id) do
      merchant = Merchant.find(txn.merchant_id)
      policy   = MerchantPolicy.for_merchant(merchant.id)

      is_partial = Decimal.compare(request.amount, txn.amount) == :lt

      if is_partial and policy.allows_partial_refunds != true do
        {:error, :partial_refunds_not_allowed}
      else
        settlement = Settlement.find_by_transaction(txn.id)

        hold_days =
          if settlement.status == :settled do
            policy.refund_hold_days
          else
            0
          end

        reference_time = settlement.settled_at || txn.captured_at

        earliest_refund_at =
          DateTime.add(reference_time, hold_days * 86_400, :second)

        if DateTime.compare(DateTime.utc_now(), earliest_refund_at) == :lt do
          {:error, :refund_on_hold}
        else
          refund_payload = %{
            gateway_ref:      txn.gateway_ref,
            amount:           request.amount,
            currency:         txn.currency,
            settlement_batch: settlement.batch_id
          }

          case Refund.execute(refund_payload) do
            {:ok, refund_id} ->
              RefundRequest.persist(%{request |
                status:       :completed,
                refund_id:    refund_id,
                completed_at: DateTime.utc_now()
              })

            {:error, reason} ->
              Logger.error("Refund failed for request #{request.id}: #{inspect(reason)}")
              {:error, reason}
          end
        end
      end
    end
    # VALIDATION: SMELL END
  end

  def cancel_refund_request(%RefundRequest{status: :pending} = request, reason) do
    RefundRequest.persist(%{request | status: :cancelled, cancel_reason: reason})
  end

  def cancel_refund_request(%RefundRequest{status: status}, _reason),
    do: {:error, "Cannot cancel refund request in #{status} state"}

  def list_refunds_for_transaction(transaction_id) do
    RefundRequest.list(transaction_id: transaction_id)
  end

  def total_refunded(transaction_id) do
    transaction_id
    |> RefundRequest.list(status: :completed)
    |> Enum.reduce(Decimal.new(0), &Decimal.add(&2, &1.amount))
  end

  defp days_since(txn) do
    DateTime.diff(DateTime.utc_now(), txn.inserted_at, :day)
  end
end
```
