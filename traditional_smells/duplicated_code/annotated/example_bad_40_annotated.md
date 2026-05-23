# Annotated Example — Duplicated Code

| Field | Value |
|---|---|
| **Smell name** | Duplicated Code |
| **Expected smell location** | `Payments.Processor.charge_card/2` and `Payments.Processor.refund_card/2` |
| **Affected functions** | `charge_card/2`, `refund_card/2` |
| **Short explanation** | Both functions independently compute the gateway processing fee using the same tiered-percentage logic based on payment method and card brand. If fee tiers are renegotiated, both functions must be updated, creating a maintenance risk. |

```elixir
defmodule Payments.Processor do
  @moduledoc """
  Handles card charging and refunds via the payment gateway, including
  transparent processing-fee calculation for reconciliation purposes.
  """

  alias Payments.{Transaction, GatewayClient, FeeRecord, Repo}

  # Gateway fee schedule (percentage of transaction amount)
  @fee_domestic_visa    0.014
  @fee_domestic_mc      0.016
  @fee_domestic_other   0.018
  @fee_international    0.028
  @fee_amex             0.032
  @flat_fee_cents       30

  # ---------------------------------------------------------------------------
  # Charge
  # ---------------------------------------------------------------------------

  @doc """
  Charges the given payment method and records the transaction with the
  associated processing fee.
  """
  def charge_card(%{amount_cents: amount, currency: currency} = payment_method, metadata) do
    with {:ok, _}    <- validate_amount(amount),
         {:ok, resp} <- GatewayClient.charge(payment_method, amount, currency) do

      # VALIDATION: SMELL START - Duplicated Code
      # VALIDATION: This is a smell because the processing-fee calculation
      # (card-brand/region tiers plus flat fee) is duplicated verbatim in
      # refund_card/2. Any renegotiated fee schedule must be applied twice.
      fee_pct =
        cond do
          payment_method.brand == "amex" ->
            @fee_amex

          payment_method.region == "international" ->
            @fee_international

          payment_method.brand == "visa" ->
            @fee_domestic_visa

          payment_method.brand == "mastercard" ->
            @fee_domestic_mc

          true ->
            @fee_domestic_other
        end

      processing_fee_cents = round(amount * fee_pct) + @flat_fee_cents
      # VALIDATION: SMELL END

      txn = %Transaction{
        gateway_ref:          resp.transaction_id,
        amount_cents:         amount,
        currency:             currency,
        processing_fee_cents: processing_fee_cents,
        direction:            :charge,
        status:               :succeeded,
        metadata:             metadata,
        inserted_at:          DateTime.utc_now()
      }

      {:ok, saved} = Repo.insert(txn)
      FeeRecord.record(saved)
      {:ok, saved}
    end
  end

  # ---------------------------------------------------------------------------
  # Refund
  # ---------------------------------------------------------------------------

  @doc """
  Issues a full or partial refund for a previous charge and records the
  associated processing fee (refunds also incur a gateway fee).
  """
  def refund_card(%Transaction{} = original_txn, refund_amount_cents) do
    with {:ok, _}    <- validate_amount(refund_amount_cents),
         :ok         <- check_refundable(original_txn, refund_amount_cents),
         {:ok, resp} <- GatewayClient.refund(original_txn.gateway_ref, refund_amount_cents) do

      payment_method = Repo.get_payment_method!(original_txn.payment_method_id)

      # VALIDATION: SMELL START - Duplicated Code
      # VALIDATION: This is a smell because the same processing-fee
      # calculation block from charge_card/2 is reproduced here. Two places
      # now own the fee logic and must be kept in sync.
      fee_pct =
        cond do
          payment_method.brand == "amex" ->
            @fee_amex

          payment_method.region == "international" ->
            @fee_international

          payment_method.brand == "visa" ->
            @fee_domestic_visa

          payment_method.brand == "mastercard" ->
            @fee_domestic_mc

          true ->
            @fee_domestic_other
        end

      processing_fee_cents = round(refund_amount_cents * fee_pct) + @flat_fee_cents
      # VALIDATION: SMELL END

      refund_txn = %Transaction{
        gateway_ref:          resp.refund_id,
        related_transaction:  original_txn.id,
        amount_cents:         refund_amount_cents,
        currency:             original_txn.currency,
        processing_fee_cents: processing_fee_cents,
        direction:            :refund,
        status:               :succeeded,
        inserted_at:          DateTime.utc_now()
      }

      {:ok, saved} = Repo.insert(refund_txn)
      FeeRecord.record(saved)
      {:ok, saved}
    end
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp validate_amount(cents) when cents > 0, do: {:ok, cents}
  defp validate_amount(_), do: {:error, :invalid_amount}

  defp check_refundable(%Transaction{status: :succeeded, direction: :charge}, _), do: :ok
  defp check_refundable(_, _), do: {:error, :not_refundable}
end
```
