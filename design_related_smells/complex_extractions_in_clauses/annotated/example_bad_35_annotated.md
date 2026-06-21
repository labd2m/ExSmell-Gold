## Metadata

- **Smell name:** Complex extractions in clauses
- **Expected smell location:** `Payments.TransactionProcessor.settle_transaction/1`
- **Affected function(s):** `settle_transaction/1`
- **Explanation:** Each of the three clauses of `settle_transaction/1` destructures eight
  fields from the `%Transaction{}` struct in the function head (`method`, `status`,
  `account_id`, `amount`, `currency`, `reference`, `gateway_token`, `descriptor`), but
  only `method` and `status` appear in guard expressions. The remaining six fields are
  used only inside the function bodies. Across three clauses this amounts to 18
  body-only extractions duplicated in function heads, making it very hard to distinguish
  the dispatch conditions from the incidental bindings at a glance.

## Code

```elixir
defmodule Payments.TransactionProcessor do
  @moduledoc """
  Settles payment transactions through configured gateways.
  Handles credit card captures, bank transfers, and wallet debits with per-method
  settlement logic, ledger recording, and receipt delivery.
  """

  alias Payments.{Gateway, Ledger, FraudGuard, ReceiptMailer, TransactionLog}
  require Logger

  @max_retry_attempts 3

  def execute(transaction_id) do
    with {:ok, txn} <- TransactionLog.fetch_pending(transaction_id),
         :ok <- FraudGuard.screen(txn),
         {:ok, result} <- settle_transaction(txn) do
      TransactionLog.mark_settled(transaction_id, result)
      {:ok, result}
    else
      {:error, :fraud_suspected} ->
        TransactionLog.flag_fraud(transaction_id)
        {:error, :fraud_suspected}

      {:error, reason} ->
        Logger.error("Transaction #{transaction_id} failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  # VALIDATION: SMELL START - Complex extractions in clauses
  # VALIDATION: This is a smell because settle_transaction/1 has three clauses each
  # extracting eight fields from %Transaction{} in the function head (method, status,
  # account_id, amount, currency, reference, gateway_token, descriptor). Only `method`
  # and `status` are used in guard expressions to select the appropriate settlement path.
  # The remaining six fields (account_id, amount, currency, reference, gateway_token,
  # descriptor) are used only inside the function bodies. Repeating all six body-only
  # bindings in every function head makes it very difficult to identify what actually
  # governs clause selection without reading each clause body in full.

  def settle_transaction(%Transaction{
        method: method,
        status: status,
        account_id: account_id,
        amount: amount,
        currency: currency,
        reference: reference,
        gateway_token: gateway_token,
        descriptor: descriptor
      })
      when method == :credit_card and status == :authorized do
    case Gateway.CreditCard.capture(gateway_token, amount, currency) do
      {:ok, capture_ref} ->
        Ledger.record_capture(account_id, amount, currency, reference, capture_ref)

        ReceiptMailer.send(account_id, %{
          amount: amount,
          currency: currency,
          descriptor: descriptor,
          reference: reference
        })

        {:ok, %{method: :credit_card, reference: reference, captured: amount}}

      {:error, reason} ->
        Logger.error("CC capture failed for account=#{account_id}: #{inspect(reason)}")
        {:error, {:capture_failed, reason}}
    end
  end

  def settle_transaction(%Transaction{
        method: method,
        status: status,
        account_id: account_id,
        amount: amount,
        currency: currency,
        reference: reference,
        gateway_token: gateway_token,
        descriptor: descriptor
      })
      when method == :bank_transfer and status == :pending do
    case Gateway.BankTransfer.initiate(gateway_token, amount, currency, descriptor) do
      {:ok, transfer_id} ->
        Ledger.record_transfer_initiated(account_id, amount, currency, reference, transfer_id)

        ReceiptMailer.send_transfer_confirmation(account_id, %{
          amount: amount,
          currency: currency,
          reference: reference,
          descriptor: descriptor
        })

        {:ok, %{method: :bank_transfer, transfer_id: transfer_id, reference: reference}}

      {:error, reason} ->
        Logger.error("Bank transfer failed for account=#{account_id}: #{inspect(reason)}")
        {:error, {:transfer_failed, reason}}
    end
  end

  def settle_transaction(%Transaction{
        method: method,
        status: status,
        account_id: account_id,
        amount: amount,
        currency: currency,
        reference: reference,
        gateway_token: gateway_token,
        descriptor: descriptor
      })
      when method == :wallet and status in [:authorized, :pending] do
    case Gateway.Wallet.debit(gateway_token, amount, currency) do
      {:ok, wallet_ref} ->
        Ledger.record_wallet_debit(account_id, amount, currency, reference, wallet_ref)

        ReceiptMailer.send(account_id, %{
          amount: amount,
          currency: currency,
          descriptor: descriptor,
          reference: reference
        })

        {:ok, %{method: :wallet, reference: reference, wallet_ref: wallet_ref}}

      {:error, :insufficient_funds} ->
        Logger.warning("Insufficient wallet funds for account=#{account_id}")
        {:error, :insufficient_funds}

      {:error, reason} ->
        Logger.error("Wallet debit failed for account=#{account_id}: #{inspect(reason)}")
        {:error, {:wallet_failed, reason}}
    end
  end

  # VALIDATION: SMELL END

  def settle_transaction(%Transaction{method: method, status: status, account_id: id}) do
    Logger.warning(
      "No settlement handler: method=#{method} status=#{status} account=#{id}"
    )

    {:error, :no_settlement_rule}
  end
end
```
