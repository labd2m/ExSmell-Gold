# Annotated Example — Compile-time Global Configuration

## Metadata

- **Smell:** Compile-time global configuration
- **Expected Smell Location:** Module attribute `@gateway_timeout` defined via `Application.fetch_env!/2` at the top of the module body
- **Affected Function(s):** `charge/3`, `refund/2`
- **Explanation:** `Application.fetch_env!/2` is called at compile-time to assign the value to the module attribute `@gateway_timeout`. At compile-time the application environment is not yet loaded, which can trigger warnings or an `ArgumentError`. The value is then frozen into the bytecode, making runtime reconfiguration impossible.

---

```elixir
defmodule Billing.PaymentGateway do
  @moduledoc """
  Handles communication with the upstream payment gateway, including
  charge and refund operations. Timeouts and retry limits are
  pulled from the application environment.
  """

  require Logger

  # VALIDATION: SMELL START - Compile-time global configuration
  # VALIDATION: This is a smell because Application.fetch_env!/2 is invoked
  # VALIDATION: during module compilation to set @gateway_timeout. At that point
  # VALIDATION: the :billing application may not yet be loaded, raising an
  # VALIDATION: ArgumentError or a compiler warning. The resolved integer is
  # VALIDATION: then baked into the compiled bytecode, so any runtime change to
  # VALIDATION: the application environment has no effect on this attribute.
  @gateway_timeout Application.fetch_env!(:billing, :gateway_timeout_ms)
  # VALIDATION: SMELL END

  @max_retries 3
  @supported_currencies ~w(USD EUR GBP BRL)

  @type charge_result ::
          {:ok, %{transaction_id: String.t(), amount: integer(), currency: String.t()}}
          | {:error, :declined | :timeout | :invalid_currency | :gateway_error}

  @type refund_result ::
          {:ok, %{refund_id: String.t(), original_transaction_id: String.t()}}
          | {:error, :not_found | :already_refunded | :timeout | :gateway_error}

  @spec charge(String.t(), integer(), String.t()) :: charge_result()
  def charge(payment_method_token, amount_cents, currency)
      when is_binary(payment_method_token) and is_integer(amount_cents) and amount_cents > 0 do
    unless currency in @supported_currencies do
      {:error, :invalid_currency}
    else
      payload = build_charge_payload(payment_method_token, amount_cents, currency)

      case execute_with_retry(:charge, payload, @max_retries) do
        {:ok, %{"transaction_id" => txn_id}} ->
          Logger.info("Charge successful",
            transaction_id: txn_id,
            amount: amount_cents,
            currency: currency
          )

          {:ok, %{transaction_id: txn_id, amount: amount_cents, currency: currency}}

        {:error, :declined} ->
          Logger.warning("Charge declined",
            amount: amount_cents,
            currency: currency
          )

          {:error, :declined}

        {:error, reason} ->
          Logger.error("Charge failed", reason: reason)
          {:error, reason}
      end
    end
  end

  @spec refund(String.t(), integer() | :full) :: refund_result()
  def refund(transaction_id, amount_or_full \\ :full)

  def refund(transaction_id, :full) when is_binary(transaction_id) do
    payload = %{transaction_id: transaction_id, refund_type: "full"}

    case execute_with_retry(:refund, payload, @max_retries) do
      {:ok, %{"refund_id" => refund_id}} ->
        {:ok, %{refund_id: refund_id, original_transaction_id: transaction_id}}

      {:error, reason} ->
        Logger.error("Full refund failed", transaction_id: transaction_id, reason: reason)
        {:error, reason}
    end
  end

  def refund(transaction_id, amount_cents)
      when is_binary(transaction_id) and is_integer(amount_cents) and amount_cents > 0 do
    payload = %{transaction_id: transaction_id, refund_type: "partial", amount: amount_cents}

    case execute_with_retry(:refund, payload, @max_retries) do
      {:ok, %{"refund_id" => refund_id}} ->
        {:ok, %{refund_id: refund_id, original_transaction_id: transaction_id}}

      {:error, reason} ->
        Logger.error("Partial refund failed",
          transaction_id: transaction_id,
          amount: amount_cents,
          reason: reason
        )

        {:error, reason}
    end
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp build_charge_payload(token, amount, currency) do
    %{
      payment_method: token,
      amount: amount,
      currency: currency,
      idempotency_key: generate_idempotency_key(token, amount)
    }
  end

  defp execute_with_retry(_operation, _payload, 0), do: {:error, :gateway_error}

  defp execute_with_retry(operation, payload, retries_left) do
    case call_gateway(operation, payload) do
      {:ok, _} = success ->
        success

      {:error, :timeout} when retries_left > 1 ->
        Logger.warning("Gateway timeout, retrying", retries_left: retries_left - 1)
        execute_with_retry(operation, payload, retries_left - 1)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp call_gateway(operation, payload) do
    # Simulates an HTTP call using @gateway_timeout for the request deadline.
    # In production this would delegate to an HTTP client such as Req or Finch.
    case simulate_http_call(operation, payload, @gateway_timeout) do
      {:ok, body} -> {:ok, body}
      {:error, :timeout} -> {:error, :timeout}
      {:error, 402} -> {:error, :declined}
      {:error, _} -> {:error, :gateway_error}
    end
  end

  defp simulate_http_call(_operation, _payload, _timeout_ms) do
    {:ok, %{"transaction_id" => "txn_#{:rand.uniform(999_999)}"}}
  end

  defp generate_idempotency_key(token, amount) do
    :crypto.hash(:sha256, "#{token}:#{amount}:#{System.system_time(:millisecond)}")
    |> Base.encode16(case: :lower)
    |> binary_part(0, 32)
  end
end
```
