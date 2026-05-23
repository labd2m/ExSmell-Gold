```elixir
defmodule Payments.RefundProcessor do
  require Logger

  alias Payments.{Refund, Gateway, LedgerEntry}
  alias Payments.Transaction

  @max_refund_window_days 90

  @doc """
  Initiates a refund for a given transaction.
  Validates eligibility, computes the breakdown, and submits to the payment gateway.
  Optionally accepts a partial amount via the :amount option.
  """
  def initiate_refund(transaction_id, opts \\ []) do
    transaction = Transaction.get!(transaction_id)
    reason = Keyword.get(opts, :reason, :customer_request)
    partial_amount = Keyword.get(opts, :amount)

    with :ok <- check_refund_eligibility(transaction),
         breakdown <- compute_refund_breakdown(transaction, partial_amount),
         {:ok, gateway_response} <-
           Gateway.issue_refund(transaction.gateway_reference, breakdown),
         {:ok, refund} <-
           Refund.create(%{
             transaction_id: transaction_id,
             amount: breakdown.refund_amount,
             currency: breakdown.currency,
             reason: reason,
             gateway_reference: gateway_response.reference_id,
             processed_at: DateTime.utc_now()
           }) do
      LedgerEntry.record_refund(refund)
      {:ok, refund}
    else
      {:error, reason} ->
        Logger.error(
          "Refund failed for transaction #{transaction_id}: #{inspect(reason)}"
        )

        {:error, reason}
    end
  end

  @doc """
  Returns the current status of a refund from the payment gateway.
  """
  def refund_status(refund_id) do
    refund = Refund.get!(refund_id)
    Gateway.check_refund_status(refund.gateway_reference)
  end

  @doc """
  Lists all refunds associated with a transaction.
  """
  def list_refunds_for_transaction(transaction_id) do
    Refund.list_by_transaction(transaction_id)
  end

  defp check_refund_eligibility(transaction) do
    days_since =
      Date.diff(Date.utc_today(), DateTime.to_date(transaction.processed_at))

    cond do
      transaction.status != :completed -> {:error, :transaction_not_completed}
      transaction.refunded -> {:error, :already_refunded}
      days_since > @max_refund_window_days -> {:error, :refund_window_expired}
      true -> :ok
    end
  end

  defp compute_refund_breakdown(transaction, partial_amount) do
    net_amount = Transaction.net_amount(transaction)
    gateway_fee = Transaction.gateway_fee(transaction)
    tax_amount = Transaction.tax_amount(transaction)
    currency = Transaction.currency(transaction)
    payment_method = Transaction.payment_method(transaction)

    refund_amount = partial_amount || net_amount

    non_refundable_fee =
      if payment_method == :credit_card, do: gateway_fee, else: Decimal.new(0)

    tax_refund =
      Decimal.mult(tax_amount, Decimal.div(refund_amount, net_amount))

    %{
      original_amount: transaction.amount,
      net_amount: net_amount,
      refund_amount: refund_amount,
      non_refundable_fee: non_refundable_fee,
      tax_refund: tax_refund,
      currency: currency,
      payment_method: payment_method
    }
  end
end
```
