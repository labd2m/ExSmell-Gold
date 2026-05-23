```elixir
defmodule PaymentProcessor do
  @moduledoc """
  Processes charges, refunds, and payment status queries via the payment gateway.
  """

  alias Payments.{Transaction, Gateway, ExchangeRateService, Ledger, WebhookDispatcher}

  @gateway_base_currency "USD"
  @rounding_precision 2
  @max_refund_days 180

  def charge(payment_params, idempotency_key) do
    with :ok <- validate_charge_params(payment_params),
         {:ok, method} <- Gateway.tokenize(payment_params.card_token),
         {:ok, rate} <-
           ExchangeRateService.get(payment_params.currency, @gateway_base_currency),
         converted_amount =
           payment_params.amount
           |> Decimal.mult(rate)
           |> Decimal.round(@rounding_precision),
         {:ok, gateway_resp} <-
           Gateway.charge(%{
             amount: converted_amount,
             currency: @gateway_base_currency,
             method: method,
             idempotency_key: idempotency_key
           }) do

      txn = %Transaction{
        id: Ecto.UUID.generate(),
        type: :charge,
        amount: payment_params.amount,
        currency: payment_params.currency,
        converted_amount: converted_amount,
        gateway_ref: gateway_resp.ref,
        status: :succeeded,
        metadata: payment_params.metadata,
        created_at: DateTime.utc_now()
      }

      Ledger.record(txn)
      WebhookDispatcher.emit(:payment_succeeded, txn)
      {:ok, txn}
    else
      {:error, :declined} ->
        WebhookDispatcher.emit(:payment_declined, %{key: idempotency_key})
        {:error, :payment_declined}

      error ->
        error
    end
  end

  def refund(original_transaction_id, refund_params) do
    with {:ok, original} <- Transaction.fetch(original_transaction_id),
         :ok <- validate_refund_eligibility(original),
         {:ok, rate} <-
           ExchangeRateService.get(refund_params.currency, @gateway_base_currency),
         converted_amount =
           refund_params.amount
           |> Decimal.mult(rate)
           |> Decimal.round(@rounding_precision),
         :ok <- validate_refund_amount(converted_amount, original.converted_amount),
         {:ok, gateway_resp} <-
           Gateway.refund(%{
             original_ref: original.gateway_ref,
             amount: converted_amount,
             currency: @gateway_base_currency
           }) do

      txn = %Transaction{
        id: Ecto.UUID.generate(),
        type: :refund,
        amount: refund_params.amount,
        currency: refund_params.currency,
        converted_amount: converted_amount,
        gateway_ref: gateway_resp.ref,
        original_transaction_id: original_transaction_id,
        status: :succeeded,
        created_at: DateTime.utc_now()
      }

      Ledger.record(txn)
      WebhookDispatcher.emit(:refund_issued, txn)
      {:ok, txn}
    end
  end

  defp validate_charge_params(%{amount: amount, currency: currency})
       when is_struct(amount, Decimal) and is_binary(currency) do
    if Decimal.gt?(amount, Decimal.new("0")), do: :ok, else: {:error, :non_positive_amount}
  end
  defp validate_charge_params(_), do: {:error, :invalid_charge_params}

  defp validate_refund_eligibility(txn) do
    age_days = DateTime.diff(DateTime.utc_now(), txn.created_at, :second) |> div(86_400)

    cond do
      txn.status != :succeeded -> {:error, :transaction_not_successful}
      age_days > @max_refund_days -> {:error, :refund_window_expired}
      true -> :ok
    end
  end

  defp validate_refund_amount(refund_amount, original_amount) do
    if Decimal.gt?(refund_amount, original_amount) do
      {:error, :refund_exceeds_original}
    else
      :ok
    end
  end
end
```
