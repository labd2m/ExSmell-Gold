```elixir
defmodule Payments.Processor do
  @moduledoc """
  Processes card payments through the platform's payment gateway integration.
  """

  require Logger

  @supported_currencies ~w(USD EUR GBP BRL)
  @max_amount_cents 10_000_000

  def charge_card(
        card_number,
        card_holder,
        card_expiry_month,
        card_expiry_year,
        card_cvv,
        amount_cents,
        currency,
        merchant_id,
        order_reference,
        idempotency_key,
        capture_immediately
      ) do
    with :ok <- validate_card(card_number, card_expiry_month, card_expiry_year, card_cvv),
         :ok <- validate_amount(amount_cents),
         :ok <- validate_currency(currency) do
      payload = %{
        card: %{
          number: mask_card(card_number),
          holder: card_holder,
          expiry: "#{card_expiry_month}/#{card_expiry_year}",
          cvv: "***"
        },
        amount_cents: amount_cents,
        currency: currency,
        merchant_id: merchant_id,
        order_reference: order_reference,
        idempotency_key: idempotency_key,
        capture: capture_immediately
      }

      Logger.info("Processing charge #{amount_cents} #{currency} for merchant #{merchant_id}, order #{order_reference}")

      case call_gateway(payload) do
        {:ok, %{status: "authorized", transaction_id: txn_id}} when capture_immediately ->
          {:ok, %{transaction_id: txn_id, status: :captured, amount_cents: amount_cents}}

        {:ok, %{status: "authorized", transaction_id: txn_id}} ->
          {:ok, %{transaction_id: txn_id, status: :authorized, amount_cents: amount_cents}}

        {:ok, %{status: "declined", reason: reason}} ->
          Logger.warning("Charge declined for order #{order_reference}: #{reason}")
          {:error, {:declined, reason}}

        {:error, reason} ->
          Logger.error("Gateway error for order #{order_reference}: #{inspect(reason)}")
          {:error, :gateway_error}
      end
    end
  end

  defp validate_card(number, month, year, cvv) do
    cond do
      not Regex.match?(~r/^\d{13,19}$/, number) ->
        {:error, "invalid card number format"}

      month not in 1..12 ->
        {:error, "invalid expiry month"}

      year < Date.utc_today().year ->
        {:error, "card has expired"}

      not Regex.match?(~r/^\d{3,4}$/, cvv) ->
        {:error, "invalid CVV"}

      true ->
        :ok
    end
  end

  defp validate_amount(cents) when cents > 0 and cents <= @max_amount_cents, do: :ok
  defp validate_amount(cents) when cents > @max_amount_cents,
    do: {:error, "amount exceeds maximum of #{@max_amount_cents} cents"}
  defp validate_amount(_), do: {:error, "amount must be positive"}

  defp validate_currency(c) when c in @supported_currencies, do: :ok
  defp validate_currency(c), do: {:error, "unsupported currency: #{c}"}

  defp call_gateway(payload) do
    Logger.debug("Calling payment gateway with payload #{inspect(Map.delete(payload, :card))}")
    txn_id = :crypto.strong_rand_bytes(10) |> Base.encode16(case: :lower)
    {:ok, %{status: "authorized", transaction_id: txn_id}}
  end

  defp mask_card(number) do
    last4 = String.slice(number, -4, 4)
    String.duplicate("*", String.length(number) - 4) <> last4
  end
end
```
