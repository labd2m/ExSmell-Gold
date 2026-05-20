# Annotated Example 16

- **Smell name:** Unrelated multi-clause function
- **Expected smell location:** `PaymentGateway.execute/1`
- **Affected function(s):** `execute/1`
- **Short explanation:** `execute/1` groups card charge, bank wire initiation, and crypto payment verification — three radically different payment methods with separate providers and validation rules — under one multi-clause function, making the code hard to maintain and impossible to document per-clause.

```elixir
defmodule PaymentGateway do
  @moduledoc """
  Unified gateway for executing payment transactions across multiple
  payment methods including cards, bank wires, and cryptocurrency.
  """

  alias PaymentGateway.{
    CardCharge,
    BankWire,
    CryptoPayment,
    StripeClient,
    BankingAPIClient,
    BlockchainClient,
    TransactionStore,
    FraudDetector,
    Webhooks
  }

  require Logger

  @doc """
  Execute a payment transaction.

  Accepts a `%CardCharge{}`, `%BankWire{}`, or `%CryptoPayment{}` struct
  and performs the appropriate payment operation.

  ## Examples

      iex> PaymentGateway.execute(%CardCharge{amount: 5000, currency: "USD", card_token: "tok_xxx"})
      {:ok, %{transaction_id: "txn_abc", status: :captured}}

  """
  # VALIDATION: SMELL START - Unrelated multi-clause function
  # VALIDATION: This is a smell because card charging, bank wire initiation,
  # and crypto payment verification involve entirely different external APIs,
  # fraud rules, settlement timelines, and compliance requirements. They share
  # no meaningful abstraction and should be separate named functions.

  def execute(%CardCharge{
        amount: amount,
        currency: currency,
        card_token: card_token,
        customer_id: customer_id,
        idempotency_key: idempotency_key
      })
      when amount > 0 do
    with {:ok, :pass} <- FraudDetector.screen(:card, customer_id, amount),
         {:ok, charge} <-
           StripeClient.charge(%{
             amount: amount,
             currency: currency,
             source: card_token,
             idempotency_key: idempotency_key,
             metadata: %{customer_id: customer_id}
           }),
         {:ok, txn} <-
           TransactionStore.record(%{
             type: :card,
             external_id: charge.id,
             amount: amount,
             currency: currency,
             customer_id: customer_id,
             status: :captured,
             captured_at: DateTime.utc_now()
           }),
         :ok <- Webhooks.emit(:payment_captured, txn) do
      Logger.info("Card charge captured: #{charge.id} for customer #{customer_id}")
      {:ok, %{transaction_id: txn.id, status: :captured}}
    end
  end

  # execute bank wire transfer initiation
  def execute(%BankWire{
        amount: amount,
        currency: currency,
        sender_account: sender,
        beneficiary_account: beneficiary,
        reference: reference,
        customer_id: customer_id
      })
      when amount > 0 do
    with :ok <- validate_wire_amount_limits(amount, currency),
         {:ok, wire} <-
           BankingAPIClient.initiate_wire(%{
             amount: amount,
             currency: currency,
             debit_account: sender,
             credit_account: beneficiary,
             reference: reference
           }),
         {:ok, txn} <-
           TransactionStore.record(%{
             type: :wire,
             external_id: wire.wire_id,
             amount: amount,
             currency: currency,
             customer_id: customer_id,
             status: :pending,
             expected_settlement: wire.settlement_date
           }) do
      Logger.info("Bank wire initiated: #{wire.wire_id}, settling #{wire.settlement_date}")
      {:ok, %{transaction_id: txn.id, status: :pending, wire_id: wire.wire_id}}
    end
  end

  # execute crypto payment verification and settlement
  def execute(%CryptoPayment{
        tx_hash: tx_hash,
        network: network,
        expected_amount: expected_amount,
        wallet_address: wallet_address,
        customer_id: customer_id
      }) do
    with {:ok, on_chain} <- BlockchainClient.fetch_transaction(network, tx_hash),
         :ok <- verify_crypto_transaction(on_chain, wallet_address, expected_amount),
         :ok <- wait_for_confirmations(network, tx_hash, required_confirmations(network)),
         {:ok, txn} <-
           TransactionStore.record(%{
             type: :crypto,
             external_id: tx_hash,
             amount: on_chain.value_usd,
             currency: "USD",
             customer_id: customer_id,
             network: network,
             status: :confirmed,
             confirmed_at: DateTime.utc_now()
           }),
         :ok <- Webhooks.emit(:crypto_payment_confirmed, txn) do
      Logger.info("Crypto payment confirmed: #{tx_hash} on #{network}")
      {:ok, %{transaction_id: txn.id, status: :confirmed}}
    end
  end

  # VALIDATION: SMELL END

  defp validate_wire_amount_limits(amount, "USD") when amount > 1_000_000_00,
    do: {:error, :exceeds_wire_limit}

  defp validate_wire_amount_limits(_, _), do: :ok

  defp verify_crypto_transaction(on_chain, expected_wallet, expected_amount) do
    cond do
      on_chain.to != expected_wallet -> {:error, :wrong_wallet}
      on_chain.value < expected_amount -> {:error, :insufficient_amount}
      true -> :ok
    end
  end

  defp wait_for_confirmations(_network, _hash, _required), do: :ok

  defp required_confirmations(:ethereum), do: 12
  defp required_confirmations(:bitcoin), do: 6
  defp required_confirmations(_), do: 3
end
```
