```elixir
defmodule MyApp.Payments.Gateway do
  @moduledoc """
  Provides a unified interface for charging customers through multiple payment
  providers. Handles idempotency, currency conversion, and transaction recording.
  """

  alias MyApp.Payments.Provider
  alias MyApp.Payments.Transaction
  alias MyApp.Payments.IdempotencyStore
  alias MyApp.Payments.CurrencyConverter
  alias MyApp.Repo

  @supported_providers [:stripe, :pagarme, :paypal]
  @default_provider :stripe
  @settlement_currency "USD"

  def build_charge(amount, currency, customer_id, description \\ nil) do
    %{
      amount: amount,
      currency: currency,
      customer_id: customer_id,
      description: description,
      idempotency_key: generate_idempotency_key(customer_id, amount, currency)
    }
  end

  def charge(charge_params, provider \\ @default_provider, opts \\ []) do
    response_mode = Keyword.get(opts, :response_mode, :id)
    convert_currency = Keyword.get(opts, :convert_currency, false)
    capture_immediately = Keyword.get(opts, :capture_immediately, true)

    unless provider in @supported_providers do
      raise ArgumentError, "unsupported provider: #{inspect(provider)}"
    end

    final_amount =
      if convert_currency and charge_params.currency != @settlement_currency do
        CurrencyConverter.convert(
          charge_params.amount,
          charge_params.currency,
          @settlement_currency
        )
      else
        charge_params.amount
      end

    if IdempotencyStore.already_processed?(charge_params.idempotency_key) do
      {:error, :duplicate_charge}
    else
      with {:ok, provider_response} <-
             Provider.charge(provider, %{
               amount: final_amount,
               currency: charge_params.currency,
               customer_id: charge_params.customer_id,
               capture: capture_immediately,
               idempotency_key: charge_params.idempotency_key
             }) do
        IdempotencyStore.mark_processed(charge_params.idempotency_key)

        transaction = %Transaction{
          id: provider_response.transaction_id,
          provider: provider,
          customer_id: charge_params.customer_id,
          amount: final_amount,
          currency: charge_params.currency,
          status: if(capture_immediately, do: :captured, else: :authorized),
          provider_ref: provider_response.ref,
          created_at: DateTime.utc_now()
        }

        Repo.insert!(transaction)

        case response_mode do
          :minimal ->
            :ok

          :id ->
            {:ok, transaction.id}

          :full ->
            {:ok, transaction}
        end
      end
    end
  end

  def capture(transaction_id) do
    with {:ok, txn} <- Repo.fetch(Transaction, transaction_id),
         {:ok, _} <- Provider.capture(txn.provider, txn.provider_ref) do
      updated = %{txn | status: :captured}
      Repo.update!(updated)
      {:ok, updated}
    end
  end

  def refund(transaction_id, amount \\ :full) do
    with {:ok, txn} <- Repo.fetch(Transaction, transaction_id) do
      refund_amount = if amount == :full, do: txn.amount, else: amount
      Provider.refund(txn.provider, txn.provider_ref, refund_amount)
    end
  end

  defp generate_idempotency_key(customer_id, amount, currency) do
    payload = "#{customer_id}:#{amount}:#{currency}:#{System.system_time(:millisecond)}"
    :crypto.hash(:sha256, payload) |> Base.encode16(case: :lower)
  end
end
```
