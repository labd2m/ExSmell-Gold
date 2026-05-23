# Annotated Example 17 — Long Parameter List

## Metadata

| Field | Value |
|---|---|
| **Smell name** | Long Parameter List |
| **Expected smell location** | `Payments.Processor.charge_card/10` |
| **Affected function(s)** | `charge_card/10` |
| **Explanation** | The function takes 10 individual parameters covering card details (card_number, expiry_month, expiry_year, cvv, cardholder_name), billing address (billing_zip, billing_country), and charge configuration (amount, currency, idempotency_key). Card details and billing info should each live in their own struct instead of being spread across a flat argument list, especially given the security-sensitive nature of the data. |

---

```elixir
# VALIDATION: SMELL START - Long Parameter List
# VALIDATION: This is a smell because `charge_card/10` takes ten positional
# parameters. Five of them (card_number, expiry_month, expiry_year, cvv,
# cardholder_name) belong to a card descriptor, two (billing_zip,
# billing_country) to a billing address, and three (amount, currency,
# idempotency_key) to the charge itself. The flat list makes it trivially
# easy to pass arguments in the wrong order, which is especially risky for
# payment-sensitive code.
defmodule Payments.Processor do
  @moduledoc """
  Handles credit-card charge authorisation via the gateway adapter,
  with idempotency, audit logging, and retry on transient failures.
  """

  require Logger

  alias Payments.Repo
  alias Payments.Schemas.ChargeRecord
  alias Payments.GatewayAdapter
  alias Payments.AuditLog

  @supported_currencies ~w(USD EUR GBP BRL)
  @max_retries 2

  def charge_card(
        card_number,
        expiry_month,
        expiry_year,
        cvv,
        cardholder_name,
        billing_zip,
        billing_country,
        amount,
        currency,
        idempotency_key
      ) do
# VALIDATION: SMELL END
    with :ok <- validate_card(card_number, expiry_month, expiry_year, cvv),
         :ok <- validate_amount(amount, currency) do
      existing = Repo.get_by(ChargeRecord, idempotency_key: idempotency_key)

      if existing do
        Logger.info("Duplicate charge request, returning existing record #{existing.id}")
        {:ok, existing}
      else
        masked_pan = mask_card_number(card_number)

        gateway_payload = %{
          pan: card_number,
          expiry_month: expiry_month,
          expiry_year: expiry_year,
          cvv: cvv,
          name: cardholder_name,
          billing_zip: billing_zip,
          billing_country: billing_country,
          amount: amount,
          currency: currency
        }

        result = attempt_charge(gateway_payload, @max_retries)

        record_attrs = %{
          masked_pan: masked_pan,
          cardholder_name: cardholder_name,
          billing_zip: billing_zip,
          billing_country: billing_country,
          amount: amount,
          currency: currency,
          idempotency_key: idempotency_key,
          status: elem(result, 0),
          gateway_ref: (elem(result, 0) == :ok && elem(result, 1)[:ref]) || nil,
          inserted_at: DateTime.utc_now()
        }

        {:ok, record} = Repo.insert(ChargeRecord.changeset(%ChargeRecord{}, record_attrs))
        AuditLog.record(:charge, record.id, masked_pan)

        result
      end
    end
  end

  defp attempt_charge(_payload, 0), do: {:error, :gateway_unavailable}

  defp attempt_charge(payload, retries_left) do
    case GatewayAdapter.charge(payload) do
      {:ok, _} = success -> success
      {:error, :transient} -> attempt_charge(payload, retries_left - 1)
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate_card(number, month, year, cvv) do
    cond do
      not Regex.match?(~r/^\d{13,19}$/, number || "") -> {:error, :invalid_card_number}
      month not in 1..12 -> {:error, :invalid_expiry_month}
      year < Date.utc_today().year -> {:error, :card_expired}
      not Regex.match?(~r/^\d{3,4}$/, cvv || "") -> {:error, :invalid_cvv}
      true -> :ok
    end
  end

  defp validate_amount(amount, currency) do
    cond do
      not is_number(amount) or amount <= 0 -> {:error, :invalid_amount}
      currency not in @supported_currencies -> {:error, {:unsupported_currency, currency}}
      true -> :ok
    end
  end

  defp mask_card_number(number) do
    last_four = String.slice(number, -4..-1)
    String.duplicate("*", String.length(number) - 4) <> last_four
  end
end
```
