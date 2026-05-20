```elixir
defmodule Payments.TransactionProcessor do
  @moduledoc """
  Processes payment transactions for card, bank transfer, and wallet methods.
  Enforces per-method limits and delegates to the appropriate payment gateway.
  """

  alias Payments.{Transaction, CardGateway, BankGateway, WalletGateway}
  alias Payments.{FraudCheck, TransactionLog, CurrencyConverter}

  @card_limit 10_000
  @bank_limit 100_000
  @wallet_limit 2_000

  # `account_id`, and `metadata` are pulled from the struct in every clause
  # head even though none of them participate in matching or guards. Only
  # `method` (structural match) and `amount` (guard) determine which clause
  # fires. Body-only and dispatch-relevant bindings are indistinguishable
  # at a glance, and the problem worsens as more clauses are added.

  def process_transaction(%Transaction{
        method: :card,
        amount: amount,
        currency: currency,
        transaction_id: transaction_id,
        account_id: account_id,
        metadata: metadata
      })
      when amount > 0 and amount <= @card_limit do
    amount_usd = CurrencyConverter.to_usd(amount, currency)

    with {:ok, :clear} <- FraudCheck.evaluate(account_id, amount_usd, metadata),
         {:ok, charge_ref} <- CardGateway.charge(account_id, amount_usd, metadata) do
      TransactionLog.record(transaction_id, :card, :success, charge_ref)
      {:ok, charge_ref}
    else
      {:error, :fraud_suspected} ->
        TransactionLog.record(transaction_id, :card, :fraud_blocked, nil)
        {:error, :fraud_suspected}

      {:error, reason} ->
        TransactionLog.record(transaction_id, :card, :failed, nil)
        {:error, reason}
    end
  end

  def process_transaction(%Transaction{
        method: :card,
        amount: amount,
        currency: currency,
        transaction_id: transaction_id,
        account_id: account_id,
        metadata: metadata
      })
      when amount > @card_limit do
    _ = {currency, metadata}
    TransactionLog.record(transaction_id, :card, :limit_exceeded, nil)
    Logger.warning("Card limit exceeded for account #{account_id}: #{amount}")
    {:error, :card_limit_exceeded}
  end

  def process_transaction(%Transaction{
        method: :bank_transfer,
        amount: amount,
        currency: currency,
        transaction_id: transaction_id,
        account_id: account_id,
        metadata: metadata
      })
      when amount > 0 and amount <= @bank_limit do
    amount_usd = CurrencyConverter.to_usd(amount, currency)
    bank_ref = Map.get(metadata, :bank_reference)

    case BankGateway.initiate_transfer(account_id, amount_usd, bank_ref) do
      {:ok, transfer_id} ->
        TransactionLog.record(transaction_id, :bank_transfer, :initiated, transfer_id)
        {:ok, transfer_id}

      {:error, reason} ->
        TransactionLog.record(transaction_id, :bank_transfer, :failed, nil)
        {:error, reason}
    end
  end

  def process_transaction(%Transaction{
        method: :wallet,
        amount: amount,
        currency: currency,
        transaction_id: transaction_id,
        account_id: account_id,
        metadata: metadata
      })
      when amount > 0 and amount <= @wallet_limit do
    amount_usd = CurrencyConverter.to_usd(amount, currency)

    case WalletGateway.debit(account_id, amount_usd, metadata) do
      {:ok, wallet_ref} ->
        TransactionLog.record(transaction_id, :wallet, :success, wallet_ref)
        {:ok, wallet_ref}

      {:error, :insufficient_funds} ->
        TransactionLog.record(transaction_id, :wallet, :insufficient_funds, nil)
        {:error, :insufficient_funds}

      {:error, reason} ->
        TransactionLog.record(transaction_id, :wallet, :failed, nil)
        {:error, reason}
    end
  end


  def process_transaction(%Transaction{method: method, amount: amount})
      when amount <= 0 do
    {:error, {:invalid_amount, method, amount}}
  end

  def process_transaction(%Transaction{method: method}) do
    {:error, {:unsupported_method, method}}
  end
end
```
