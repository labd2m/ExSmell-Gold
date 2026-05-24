```elixir
defmodule Payments.RefundProcessor do
  @moduledoc """
  Handles refund requests against captured payment transactions.
  Applies merchant refund policies and routes to the appropriate gateway.
  """

  require Logger

  alias Payments.{Transaction, Merchant, RefundRequest, GatewayRouter}
  alias Payments.Ledger
  alias Repo

  @max_refund_window_days 180
  @partial_refund_min_cents 100

  def process(transaction_id, %{amount_cents: requested_amount} = params) do
    with {:ok, txn} <- Transaction.fetch(transaction_id),
         {:ok, merchant} <- Merchant.fetch(txn.merchant_id) do
      validate_and_refund(txn, merchant, requested_amount, params)
    end
  end

  defp validate_and_refund(txn, merchant, requested_amount, params) do
    cond do
      txn.status != :captured ->
        {:error, :transaction_not_capturable}

      days_since_capture(txn.captured_at) > @max_refund_window_days ->
        {:error, :refund_window_expired}

      requested_amount > txn.amount_cents ->
        {:error, :amount_exceeds_transaction}

      requested_amount < @partial_refund_min_cents and requested_amount != txn.amount_cents ->
        {:error, :partial_refund_below_minimum}

      merchant.refund_policy == :no_refunds ->
        {:error, :refunds_disabled_by_merchant}

      true ->
        approve? =
          merchant.refund_policy == :auto_approve or
            requested_amount <= merchant.auto_approve_threshold_cents

        if approve? do
          execute_refund(txn, merchant, requested_amount, params)
        else
          queue_for_manual_review(txn, merchant, requested_amount, params)
        end
    end
  end

  defp determine_refund_method(txn, merchant) do
    case txn.payment_method do
      :credit_card ->
        {:gateway, merchant.gateway_id, txn.gateway_reference}

      :bank_transfer ->
        {:bank, txn.bank_account_reference}

      :store_credit ->
        {:credit_wallet, txn.wallet_id}

      _ ->
        {:gateway, merchant.gateway_id, txn.gateway_reference}
    end
  end

  defp execute_refund(txn, merchant, amount_cents, params) do
    refund_method = determine_refund_method(txn, merchant)

    case GatewayRouter.issue_refund(refund_method, amount_cents) do
      {:ok, gateway_response} ->
        refund = %RefundRequest{
          transaction_id: txn.id,
          merchant_id: merchant.id,
          amount_cents: amount_cents,
          reason: params[:reason],
          method: elem(refund_method, 0),
          gateway_refund_id: gateway_response.refund_id,
          status: :completed,
          processed_at: DateTime.utc_now()
        }

        Repo.transaction(fn ->
          {:ok, saved} = Repo.insert(refund)
          Ledger.record_refund(txn.id, amount_cents)
          saved
        end)
        |> case do
          {:ok, saved} ->
            Logger.info("Refund #{saved.id} completed for txn #{txn.id}")
            {:ok, saved}

          {:error, reason} ->
            Logger.error("Refund persistence failed: #{inspect(reason)}")
            {:error, :persistence_failed}
        end

      {:error, reason} ->
        Logger.error("Gateway refused refund for txn #{txn.id}: #{inspect(reason)}")
        {:error, :gateway_declined}
    end
  end

  defp queue_for_manual_review(txn, merchant, amount_cents, params) do
    refund = %RefundRequest{
      transaction_id: txn.id,
      merchant_id: merchant.id,
      amount_cents: amount_cents,
      reason: params[:reason],
      status: :pending_review,
      created_at: DateTime.utc_now()
    }

    case Repo.insert(refund) do
      {:ok, saved} ->
        Logger.info("Refund #{saved.id} queued for manual review")
        {:ok, {:pending_review, saved}}

      {:error, changeset} ->
        {:error, :persistence_failed}
    end
  end

  defp days_since_capture(captured_at) do
    Date.diff(Date.utc_today(), DateTime.to_date(captured_at))
  end
end
```
