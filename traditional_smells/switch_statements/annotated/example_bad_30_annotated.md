# Annotated Example — Switch Statements

## Metadata

- **Smell name:** Switch Statements
- **Expected smell location:** `PaymentProcessor.processing_fee/2` and `PaymentProcessor.gateway_timeout/1`
- **Affected functions:** `processing_fee/2`, `gateway_timeout/1`
- **Short explanation:** The same `case` branching over payment method (`:credit_card`, `:debit_card`, `:bank_transfer`, `:crypto`, `:wallet`) is duplicated in `processing_fee/2` and `gateway_timeout/1`. Adding a new payment method requires updating both functions.

---

```elixir
defmodule PaymentProcessor do
  @moduledoc """
  Orchestrates payment authorisation, capture, and refund flows.
  Handles per-method fee structures and gateway timeout thresholds
  for a multi-method payment platform.
  """

  alias PaymentProcessor.{
    Transaction,
    GatewayClient,
    AuditLog,
    FraudEngine
  }

  @type payment_method :: :credit_card | :debit_card | :bank_transfer | :crypto | :wallet

  @spec authorise(Transaction.t()) :: {:ok, Transaction.t()} | {:error, term()}
  def authorise(%Transaction{} = txn) do
    with :ok <- FraudEngine.check(txn),
         fee = processing_fee(txn.amount, txn.payment_method),
         timeout = gateway_timeout(txn.payment_method),
         {:ok, auth_code} <- GatewayClient.authorise(txn, timeout: timeout) do
      updated_txn = %{txn | fee: fee, auth_code: auth_code, status: :authorised}
      AuditLog.record(:authorised, updated_txn)
      {:ok, updated_txn}
    end
  end

  @spec capture(%Transaction{status: :authorised}) ::
          {:ok, Transaction.t()} | {:error, term()}
  def capture(%Transaction{status: :authorised} = txn) do
    case GatewayClient.capture(txn.auth_code) do
      {:ok, capture_ref} ->
        updated = %{txn | capture_ref: capture_ref, status: :captured}
        AuditLog.record(:captured, updated)
        {:ok, updated}

      {:error, reason} ->
        AuditLog.record(:capture_failed, txn, %{reason: reason})
        {:error, reason}
    end
  end

  @spec refund(Transaction.t(), float()) :: {:ok, map()} | {:error, term()}
  def refund(%Transaction{status: :captured} = txn, amount) when amount > 0 do
    cond do
      amount > txn.amount ->
        {:error, :refund_exceeds_original}

      true ->
        case GatewayClient.refund(txn.capture_ref, amount) do
          {:ok, refund_ref} ->
            AuditLog.record(:refunded, txn, %{amount: amount, ref: refund_ref})
            {:ok, %{refund_ref: refund_ref, amount: amount}}

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  # VALIDATION: SMELL START - Switch Statements
  # VALIDATION: This is a smell because the same case branching on `payment_method`
  # also appears in `gateway_timeout/1` below. Both enumerate :credit_card, :debit_card,
  # :bank_transfer, :crypto, :wallet — a new method requires changes in both.
  @spec processing_fee(float(), payment_method()) :: float()
  def processing_fee(amount, payment_method) do
    rate =
      case payment_method do
        :credit_card   -> 0.029
        :debit_card    -> 0.015
        :bank_transfer -> 0.008
        :crypto        -> 0.010
        :wallet        -> 0.005
      end

    Float.round(amount * rate, 2)
  end
  # VALIDATION: SMELL END

  # VALIDATION: SMELL START - Switch Statements
  # VALIDATION: This is a smell because the same case branching on `payment_method`
  # already appeared in `processing_fee/2` above. The identical set of method atoms
  # is repeated, making this logic hard to keep in sync when new methods are added.
  @spec gateway_timeout(payment_method()) :: integer()
  def gateway_timeout(payment_method) do
    case payment_method do
      :credit_card   -> 10_000
      :debit_card    -> 10_000
      :bank_transfer -> 30_000
      :crypto        -> 60_000
      :wallet        -> 5_000
    end
  end
  # VALIDATION: SMELL END

  @spec supported_methods() :: [payment_method()]
  def supported_methods do
    [:credit_card, :debit_card, :bank_transfer, :crypto, :wallet]
  end

  @spec estimate_total(float(), payment_method()) :: map()
  def estimate_total(amount, method) do
    fee = processing_fee(amount, method)

    %{
      amount: amount,
      fee: fee,
      total: Float.round(amount + fee, 2),
      method: method
    }
  end
end
```
