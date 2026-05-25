```elixir
defmodule Payments.ChargeBuilder do
  @moduledoc """
  Constructs the full charge payload for a payment transaction,
  combining the base amount, applicable taxes, platform fees,
  and metadata required by the downstream payment gateway.
  """

  alias Payments.{Transaction, TaxCalculator, PlatformFee, GatewayPayload}

  require Logger

  @platform_fee_rate 0.015
  @minimum_charge_cents 50

  @spec build(Transaction.t()) :: {:ok, GatewayPayload.t()} | {:error, atom()}
  def build(%Transaction{} = txn) do
    with :ok <- validate_transaction(txn),
         {:ok, tax} <- TaxCalculator.compute(txn),
         {:ok, platform_fee} <- compute_platform_fee(txn),
         {:ok, payload} <- assemble_payload(txn, tax, platform_fee) do
      Logger.debug("Built charge payload txn=#{txn.id} total=#{payload.total_cents}")
      {:ok, payload}
    end
  end

  defp assemble_payload(%Transaction{} = txn, tax, platform_fee) do
    base_cents = dollars_to_cents(txn.amount)
    tax_cents = dollars_to_cents(tax.amount)
    fee_cents = dollars_to_cents(platform_fee)
    total_cents = base_cents + tax_cents + fee_cents

    if total_cents < @minimum_charge_cents do
      {:error, :charge_below_minimum}
    else
      payload = %GatewayPayload{
        idempotency_key: txn.id,
        amount_cents: total_cents,
        currency: txn.currency,
        customer_id: txn.customer_id,
        payment_method_id: txn.payment_method_id,
        description: txn.description,
        metadata: %{
          platform_fee_cents: fee_cents,
          tax_cents: tax_cents,
          tax_jurisdiction: tax.jurisdiction
        }
      }

      {:ok, payload}
    end
  end

  defp compute_platform_fee(%Transaction{amount: amount}) do
    fee = Float.round(amount * @platform_fee_rate, 2)
    {:ok, fee}
  end

  defp apply_cross_border_surcharge(
         %GatewayPayload{currency: charge_currency} = payload,
         issuer_currency
       )
       when charge_currency != issuer_currency do
    surcharge_cents = round(payload.amount_cents * 0.01)

    %{payload
      | amount_cents: payload.amount_cents + surcharge_cents,
        metadata: Map.put(payload.metadata, :cross_border_surcharge_cents, surcharge_cents)}
  end

  defp apply_cross_border_surcharge(payload, _issuer_currency), do: payload

  defp validate_transaction(%Transaction{amount: amount}) when amount <= 0,
    do: {:error, :invalid_amount}

  defp validate_transaction(%Transaction{customer_id: nil}),
    do: {:error, :missing_customer}

  defp validate_transaction(%Transaction{payment_method_id: nil}),
    do: {:error, :missing_payment_method}

  defp validate_transaction(_txn), do: :ok

  defp dollars_to_cents(amount) do
    round(amount * 100)
  end
end
```
