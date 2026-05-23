# Annotated Example 07 — Long Parameter List

## Metadata

- **Smell name:** Long Parameter List
- **Expected smell location:** `Payments.Processor.charge_customer/12`
- **Affected function(s):** `charge_customer/12`
- **Short explanation:** The function takes 12 positional parameters merging customer identity, payment method details, charge amount/currency, metadata, and flags. A `PaymentRequest` struct would remove the fragile ordering and allow safer call sites.

---

```elixir
defmodule Payments.Processor do
  @moduledoc """
  Processes customer charges through configured payment gateway adapters.
  """

  require Logger

  alias Payments.{Gateway, Receipt, FraudChecker, AuditLog}

  @supported_currencies ~w(USD EUR GBP BRL JPY)
  @max_charge_amount Decimal.new("50000.00")

  # VALIDATION: SMELL START - Long Parameter List
  # VALIDATION: This is a smell because 12 positional parameters conflate customer data,
  # VALIDATION: card credentials, transaction parameters, and behavioral flags into one
  # VALIDATION: signature. A PaymentRequest struct would encapsulate this cleanly.
  def charge_customer(
        customer_id,
        customer_email,
        card_token,
        card_last_four,
        card_brand,
        amount,
        currency,
        description,
        idempotency_key,
        capture_immediately,
        send_receipt,
        metadata
      ) do
    # VALIDATION: SMELL END

    with :ok <- validate_amount(amount),
         :ok <- validate_currency(currency),
         :ok <- FraudChecker.assess(customer_id, amount, currency),
         :ok <- validate_idempotency(idempotency_key) do

      charge_request = %{
        customer_id: customer_id,
        card_token: card_token,
        amount: amount,
        currency: currency,
        description: description,
        capture: capture_immediately,
        idempotency_key: idempotency_key,
        metadata: metadata || %{}
      }

      case Gateway.charge(charge_request) do
        {:ok, gateway_response} ->
          receipt = %Receipt{
            id: gateway_response.charge_id,
            customer_id: customer_id,
            customer_email: customer_email,
            card_last_four: card_last_four,
            card_brand: card_brand,
            amount: amount,
            currency: currency,
            description: description,
            captured: capture_immediately,
            status: gateway_response.status,
            charged_at: DateTime.utc_now()
          }

          AuditLog.record(:charge_success, %{
            customer_id: customer_id,
            receipt_id: receipt.id,
            amount: amount,
            currency: currency
          })

          if send_receipt do
            Payments.Mailer.send_receipt(customer_email, receipt)
          end

          Logger.info("Charge successful: #{receipt.id} for customer #{customer_id}")
          {:ok, receipt}

        {:error, %{code: :insufficient_funds}} ->
          Logger.warning("Charge declined: insufficient funds for customer #{customer_id}")
          {:error, :insufficient_funds}

        {:error, reason} ->
          AuditLog.record(:charge_failure, %{customer_id: customer_id, reason: reason})
          Logger.error("Charge failed for #{customer_id}: #{inspect(reason)}")
          {:error, reason}
      end
    end
  end

  def refund(charge_id, amount \\ nil) do
    case Gateway.refund(charge_id, amount) do
      {:ok, refund} ->
        Logger.info("Refund issued for charge #{charge_id}")
        {:ok, refund}

      {:error, reason} ->
        Logger.error("Refund failed for #{charge_id}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp validate_amount(a) when is_struct(a, Decimal) do
    cond do
      Decimal.lt?(a, Decimal.new("0.01")) -> {:error, :amount_too_small}
      Decimal.gt?(a, @max_charge_amount) -> {:error, :amount_too_large}
      true -> :ok
    end
  end

  defp validate_amount(_), do: {:error, :invalid_amount}

  defp validate_currency(c) when c in @supported_currencies, do: :ok
  defp validate_currency(c), do: {:error, {:unsupported_currency, c}}

  defp validate_idempotency(k) when is_binary(k) and byte_size(k) > 0, do: :ok
  defp validate_idempotency(_), do: {:error, :missing_idempotency_key}
end
```
