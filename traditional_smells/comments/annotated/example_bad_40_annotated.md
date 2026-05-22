# Code Smell Annotation

- **Smell name:** Comments
- **Expected smell location:** `PaymentProcessor` module, function `capture_payment/2`
- **Affected function(s):** `capture_payment/2`
- **Short explanation:** `capture_payment/2` is documented using plain `#` comment blocks rather than `@doc`, so the documentation is discarded by the compiler and unavailable through ExDoc or IEx.

```elixir
defmodule PaymentProcessor do
  @moduledoc """
  Manages payment authorisations, captures, refunds, and reconciliation
  for the e-commerce checkout pipeline.
  """

  alias PaymentProcessor.{Gateway, Ledger, PaymentRecord}
  require Logger

  @max_capture_attempts 3
  @supported_currencies ~w(USD EUR GBP BRL)

  @doc """
  Authorises a payment intent with the configured payment gateway.
  Returns `{:ok, %PaymentRecord{status: :authorised}}` or `{:error, reason}`.
  """
  def authorise(%{amount: amount, currency: currency, method: method} = intent)
      when is_integer(amount) and amount > 0 do
    with :ok <- validate_currency(currency),
         {:ok, gateway_ref} <- Gateway.authorise(method, amount, currency) do
      record = %PaymentRecord{
        gateway_ref: gateway_ref,
        amount: amount,
        currency: currency,
        status: :authorised,
        created_at: DateTime.utc_now()
      }

      Ledger.insert(record)
    end
  end

  # VALIDATION: SMELL START - Comments
  # VALIDATION: This is a smell because `capture_payment/2` relies on plain `#` comment lines
  # VALIDATION: for documentation instead of the `@doc` attribute. Elixir ignores these at
  # VALIDATION: compile time, so they are never surfaced in generated docs or IEx help.

  # Captures a previously authorised payment.
  #
  # Arguments:
  #   payment_id  - binary, the internal identifier of an :authorised PaymentRecord
  #   opts        - keyword list:
  #       :partial_amount  - integer, capture less than the full authorised amount (optional)
  #       :idempotency_key - binary, used to safely retry the request (optional)
  #
  # Behaviour:
  #   - Fetches the existing record from the ledger.
  #   - Validates status is :authorised (returns {:error, :wrong_status} otherwise).
  #   - Attempts capture with up to @max_capture_attempts retries on transient errors.
  #   - On success, updates the record status to :captured in the ledger.
  #   - On final failure, marks the record as :failed.
  #
  # Returns {:ok, %PaymentRecord{}} or {:error, reason}.
  def capture_payment(payment_id, opts \\ []) when is_binary(payment_id) do
    partial = Keyword.get(opts, :partial_amount)
    idempotency_key = Keyword.get(opts, :idempotency_key)

    with {:ok, %PaymentRecord{status: :authorised} = record} <- Ledger.fetch(payment_id) do
      amount = partial || record.amount

      result =
        attempt_capture(record.gateway_ref, amount, idempotency_key, @max_capture_attempts)

      case result do
        {:ok, _} ->
          Ledger.update(payment_id, %{status: :captured, captured_amount: amount})

        {:error, reason} ->
          Logger.error("Capture failed for #{payment_id}: #{inspect(reason)}")
          Ledger.update(payment_id, %{status: :failed})
          {:error, reason}
      end
    else
      {:ok, %PaymentRecord{status: status}} -> {:error, {:wrong_status, status}}
      {:error, :not_found} -> {:error, :payment_not_found}
    end
  end

  # VALIDATION: SMELL END

  @doc """
  Initiates a full or partial refund on a captured payment.
  """
  def refund(payment_id, opts \\ []) when is_binary(payment_id) do
    amount = Keyword.get(opts, :amount)

    with {:ok, %PaymentRecord{status: :captured, gateway_ref: ref, amount: original}} <-
           Ledger.fetch(payment_id) do
      refund_amount = amount || original
      Gateway.refund(ref, refund_amount)
    end
  end

  @doc """
  Validates that the given currency code is supported by the processor.
  """
  def validate_currency(currency) when is_binary(currency) do
    if currency in @supported_currencies,
      do: :ok,
      else: {:error, {:unsupported_currency, currency}}
  end

  defp attempt_capture(_ref, _amount, _key, 0), do: {:error, :max_retries_exceeded}

  defp attempt_capture(ref, amount, key, attempts_left) do
    case Gateway.capture(ref, amount, idempotency_key: key) do
      {:ok, _} = success -> success
      {:error, :transient} -> attempt_capture(ref, amount, key, attempts_left - 1)
      {:error, reason} -> {:error, reason}
    end
  end
end
```
