# Annotated Example — Duplicated Code

## Metadata

- **Smell name:** Duplicated Code
- **Expected smell location:** `PaymentProcessor.charge/2` and `PaymentProcessor.refund/2`
- **Affected functions:** `charge/2`, `refund/2`
- **Short explanation:** Both functions independently fetch the exchange rate, apply it to convert the amount to the gateway's base currency (USD), and round the result. This currency-conversion block is duplicated instead of extracted into a shared helper.

---

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
         # VALIDATION: SMELL START - Duplicated Code
         # VALIDATION: This is a smell because the exchange-rate fetch, conversion
         # multiplication, and Decimal rounding below are reproduced identically
         # in `refund/2`. Any change to conversion logic (precision, source of
         # rates) must be applied in two places.
         {:ok, rate} <-
           ExchangeRateService.get(payment_params.currency, @gateway_base_currency),
         converted_amount =
           payment_params.amount
           |> Decimal.mult(rate)
           |> Decimal.round(@rounding_precision),
         # VALIDATION: SMELL END
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
         # VALIDATION: SMELL START - Duplicated Code
         # VALIDATION: This is a smell because this currency-conversion block
         # duplicates the one in `charge/2`, creating two maintenance sites for
         # exchange-rate logic.
         {:ok, rate} <-
           ExchangeRateService.get(refund_params.currency, @gateway_base_currency),
         converted_amount =
           refund_params.amount
           |> Decimal.mult(rate)
           |> Decimal.round(@rounding_precision),
         # VALIDATION: SMELL END
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
