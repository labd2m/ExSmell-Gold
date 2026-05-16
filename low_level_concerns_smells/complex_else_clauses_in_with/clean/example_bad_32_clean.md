```elixir
defmodule Payments.ChargeProcessor do
  @moduledoc """
  Orchestrates payment charges: card lookup, fraud screening,
  gateway authorization, ledger posting, and receipt emission.
  """

  alias Payments.{CardVault, FraudEngine, Gateway, Ledger, ReceiptMailer}
  require Logger

  @supported_currencies ~w(USD EUR GBP BRL)

  @doc """
  Charges `amount_cents` in `currency` to the stored card for `customer_id`.

  Returns `{:ok, charge}` or a domain-specific error tuple.
  """
  @spec charge_customer(String.t(), pos_integer(), String.t()) ::
          {:ok, map()}
          | {:error, :card_not_found}
          | {:error, :fraud_blocked, String.t()}
          | {:error, :gateway_declined, String.t()}
          | {:error, :ledger_failed}
          | {:error, :unsupported_currency}
  def charge_customer(customer_id, amount_cents, currency) do
    unless currency in @supported_currencies do
      {:error, :unsupported_currency}
    else
      with {:ok, card}   <- CardVault.fetch_default(customer_id),
           :ok           <- FraudEngine.screen(%{card: card, amount: amount_cents, currency: currency}),
           {:ok, auth}   <- Gateway.authorize(card.token, amount_cents, currency),
           {:ok, _entry} <- Ledger.post_charge(%{
                              customer_id:  customer_id,
                              gateway_ref:  auth.reference,
                              amount_cents: amount_cents,
                              currency:     currency,
                              authorized_at: auth.timestamp
                            }) do
        charge = %{
          id:           auth.reference,
          customer_id:  customer_id,
          amount_cents: amount_cents,
          currency:     currency,
          status:       :captured,
          charged_at:   DateTime.utc_now()
        }

        ReceiptMailer.send_async(customer_id, charge)
        Logger.info("Charge #{charge.id} captured for customer #{customer_id}")
        {:ok, charge}
      else
        {:error, :not_found} ->
          Logger.warn("No default card for customer #{customer_id}")
          {:error, :card_not_found}

        {:blocked, reason} ->
          Logger.warn("Fraud block for customer #{customer_id}: #{reason}")
          {:error, :fraud_blocked, reason}

        {:declined, code, message} ->
          Logger.info("Gateway declined customer #{customer_id}: [#{code}] #{message}")
          {:error, :gateway_declined, message}

        {:error, :ledger, detail} ->
          Logger.error("Ledger post failed: #{inspect(detail)}")
          {:error, :ledger_failed}
      end
    end
  end
end
```
