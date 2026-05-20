## Metadata

- **Smell name**: Complex extractions in clauses
- **Expected smell location**: `charge_payment_method/2`, all three clauses
- **Affected function(s)**: `charge_payment_method/2`
- **Short explanation**: All three clauses of `charge_payment_method/2` extract `id`, `holder_name`, `last_four`, `expiry`, and `billing_address` from `%PaymentMethod{}` for body-only use. Only `method_type` and `status` appear in guard expressions. This mixed extraction makes it unnecessarily difficult for a reader to identify which fields are being used for clause selection versus runtime computation.

```elixir
defmodule Payments.ChargeProcessor do
  alias Payments.{PaymentMethod, Transaction, GatewayClient, FraudEngine, ReceiptMailer}
  require Logger

  @moduledoc """
  Handles charge processing for various payment method types.
  Supports credit card, ACH, and digital wallet payments.
  """

  @max_card_charge 50_000_00
  @ach_processing_days 3

  # VALIDATION: SMELL START - Complex extractions in clauses
  # VALIDATION: This is a smell because `id`, `holder_name`, `last_four`, `expiry`, and
  # VALIDATION: `billing_address` are extracted in each clause head for body-only use,
  # VALIDATION: while only `method_type` and `status` participate in guards. The uniform
  # VALIDATION: exhaustive destructuring across all three clauses obscures what actually
  # VALIDATION: triggers each clause.
  def charge_payment_method(
        %PaymentMethod{
          id: method_id,
          method_type: method_type,
          status: status,
          holder_name: holder_name,
          last_four: last_four,
          expiry: expiry,
          billing_address: billing_address
        },
        amount_cents
      )
      when method_type == :credit_card and status == :active do
    Logger.info("Charging credit card ending #{last_four} for #{amount_cents} cents")

    fraud_result = FraudEngine.evaluate(%{
      method_id: method_id,
      holder: holder_name,
      amount_cents: amount_cents,
      billing_address: billing_address
    })

    with :ok <- validate_expiry(expiry),
         :ok <- validate_charge_limit(amount_cents, @max_card_charge),
         {:ok, :low_risk} <- fraud_result do
      case GatewayClient.charge_card(%{
             method_id: method_id,
             amount_cents: amount_cents,
             last_four: last_four,
             billing_zip: billing_address.zip
           }) do
        {:ok, gateway_txn_id} ->
          txn = Transaction.create!(%{
            method_id: method_id,
            amount_cents: amount_cents,
            gateway_txn_id: gateway_txn_id,
            type: :credit_card
          })

          ReceiptMailer.send_receipt(holder_name, txn)
          {:ok, txn}

        {:error, reason} ->
          Logger.error("Card charge failed for method #{method_id}: #{inspect(reason)}")
          {:error, reason}
      end
    end
  end

  def charge_payment_method(
        %PaymentMethod{
          id: method_id,
          method_type: method_type,
          status: status,
          holder_name: holder_name,
          last_four: last_four,
          expiry: _expiry,
          billing_address: billing_address
        },
        amount_cents
      )
      when method_type == :ach and status == :active do
    Logger.info("Initiating ACH transfer for account ending #{last_four}")

    case GatewayClient.initiate_ach(%{
           method_id: method_id,
           amount_cents: amount_cents,
           routing_last_four: last_four,
           billing_address: billing_address
         }) do
      {:ok, ach_reference} ->
        txn = Transaction.create!(%{
          method_id: method_id,
          amount_cents: amount_cents,
          ach_reference: ach_reference,
          type: :ach,
          expected_settlement_days: @ach_processing_days
        })

        ReceiptMailer.send_ach_pending(holder_name, txn, @ach_processing_days)
        {:ok, txn}

      {:error, reason} ->
        Logger.error("ACH initiation failed for method #{method_id}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  def charge_payment_method(
        %PaymentMethod{
          id: method_id,
          method_type: method_type,
          status: status,
          holder_name: holder_name,
          last_four: _last_four,
          expiry: _expiry,
          billing_address: billing_address
        },
        amount_cents
      )
      when method_type == :digital_wallet and status == :active do
    Logger.info("Processing digital wallet payment for method #{method_id}")

    fraud_result = FraudEngine.evaluate(%{
      method_id: method_id,
      holder: holder_name,
      amount_cents: amount_cents,
      billing_address: billing_address
    })

    with {:ok, :low_risk} <- fraud_result do
      case GatewayClient.charge_wallet(%{method_id: method_id, amount_cents: amount_cents}) do
        {:ok, wallet_txn_id} ->
          txn = Transaction.create!(%{
            method_id: method_id,
            amount_cents: amount_cents,
            wallet_txn_id: wallet_txn_id,
            type: :digital_wallet
          })

          ReceiptMailer.send_receipt(holder_name, txn)
          {:ok, txn}

        {:error, reason} ->
          Logger.error("Wallet payment failed for method #{method_id}: #{inspect(reason)}")
          {:error, reason}
      end
    end
  end
  # VALIDATION: SMELL END

  defp validate_expiry(%{month: m, year: y}) do
    today = Date.utc_today()
    if y > today.year or (y == today.year and m >= today.month), do: :ok, else: {:error, :card_expired}
  end

  defp validate_charge_limit(amount, max) when amount <= max, do: :ok
  defp validate_charge_limit(_amount, _max), do: {:error, :exceeds_limit}
end
```
