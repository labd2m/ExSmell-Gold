# Code Smell Annotation

- **Smell name:** Working with invalid data
- **Expected smell location:** `PaymentProcessor.charge/3`, where `amount` is passed directly to `Decimal.new/1`
- **Affected function(s):** `charge/3`
- **Short explanation:** The `charge/3` function receives `amount` as a parameter and passes it directly to `Decimal.new/1` without first checking that it is a valid numeric or string-encoded numeric value. If a caller passes an atom, a list, or any other unexpected type, the error will be raised inside the Decimal library with a confusing message unrelated to the original bad input.

```elixir
defmodule MyApp.Payments.PaymentProcessor do
  @moduledoc """
  Handles payment charging, authorization, and settlement against the
  configured payment gateway adapter. Supports one-time and recurring charges.
  """

  require Logger

  alias MyApp.Payments.{Gateway, TransactionLog, Ledger}
  alias MyApp.Accounts.Customer

  @supported_currencies ~w(USD EUR GBP BRL CAD AUD)
  @max_retry_attempts 3

  @type charge_opts :: [
          idempotency_key: String.t(),
          description: String.t(),
          metadata: map(),
          capture: boolean()
        ]

  @spec charge(Customer.t(), term(), String.t(), charge_opts()) ::
          {:ok, map()} | {:error, atom()}
  def charge(customer, amount, currency, opts \\ []) do
    idempotency_key = Keyword.get(opts, :idempotency_key, generate_idempotency_key())
    description = Keyword.get(opts, :description, "Charge")
    capture = Keyword.get(opts, :capture, true)

    unless currency in @supported_currencies do
      Logger.warning("Unsupported currency: #{currency}")
      {:error, :unsupported_currency}
    else
      # VALIDATION: SMELL START - Working with invalid data
      # VALIDATION: This is a smell because `amount` is passed directly to `Decimal.new/1`
      # VALIDATION: without checking that it is a number or a numeric string. If `amount`
      # VALIDATION: is an atom, a list, or a map, the error will surface inside the
      # VALIDATION: Decimal library with a message that doesn't mention the caller.
      decimal_amount = Decimal.new(amount)
      # VALIDATION: SMELL END

      charge_params = %{
        customer_id: customer.id,
        amount: decimal_amount,
        currency: currency,
        description: description,
        idempotency_key: idempotency_key,
        capture: capture,
        metadata: Keyword.get(opts, :metadata, %{})
      }

      with {:ok, auth} <- Gateway.authorize(charge_params),
           {:ok, tx} <- maybe_capture(auth, capture),
           :ok <- TransactionLog.record(tx),
           :ok <- Ledger.debit(customer.id, decimal_amount, currency) do
        Logger.info("Payment charged: #{tx.id} for customer #{customer.id}")
        {:ok, tx}
      else
        {:error, reason} = err ->
          Logger.error("Payment failed for customer #{customer.id}: #{inspect(reason)}")
          err
      end
    end
  end

  @spec refund(String.t(), term() | nil) :: {:ok, map()} | {:error, atom()}
  def refund(transaction_id, amount \\ nil) do
    with {:ok, original_tx} <- TransactionLog.fetch(transaction_id) do
      refund_amount =
        if amount do
          Decimal.new(amount)
        else
          original_tx.amount
        end

      Gateway.refund(transaction_id, refund_amount)
    end
  end

  @spec retry_failed(String.t()) :: {:ok, map()} | {:error, atom()}
  def retry_failed(transaction_id) do
    with {:ok, tx} <- TransactionLog.fetch(transaction_id),
         true <- tx.attempt_count < @max_retry_attempts do
      Gateway.retry(transaction_id)
    else
      false -> {:error, :max_retries_exceeded}
      err -> err
    end
  end

  # Private helpers

  defp maybe_capture(auth, true), do: Gateway.capture(auth.id)
  defp maybe_capture(auth, false), do: {:ok, auth}

  defp generate_idempotency_key do
    :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
  end
end
```
