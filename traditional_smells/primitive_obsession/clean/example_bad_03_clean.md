```elixir
defmodule Payments.CardProcessor do
  @moduledoc """
  Handles credit-card tokenisation, validation, and charge submission
  against the payment gateway. PCI-DSS sensitive fields are never
  persisted directly; only tokens are stored after the initial call.
  """

  require Logger

  @gateway_endpoint "https://gateway.internal/v2/charge"
  @supported_brands ~w(visa mastercard amex discover)

  @spec tokenize_card(String.t(), integer(), integer(), String.t()) ::
          {:ok, String.t()} | {:error, String.t()}
  def tokenize_card(card_number, exp_month, exp_year, cvv) do
    with {:ok} <- validate_card(card_number, exp_month, exp_year, cvv) do
      token = generate_token(card_number, exp_month, exp_year)

      Logger.info(
        "Card tokenised successfully: #{mask_card_number(card_number)} " <>
          "exp #{exp_month}/#{exp_year}"
      )

      {:ok, token}
    end
  end

  @spec validate_card(String.t(), integer(), integer(), String.t()) ::
          {:ok} | {:error, String.t()}
  def validate_card(card_number, exp_month, exp_year, cvv) do
    with :ok <- check_card_number_format(card_number),
         :ok <- check_luhn(card_number),
         :ok <- check_expiry(exp_month, exp_year),
         :ok <- check_cvv(cvv, detect_brand(card_number)) do
      {:ok}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  @spec charge_card(String.t(), integer(), integer(), String.t(), float()) ::
          {:ok, map()} | {:error, String.t()}
  def charge_card(card_number, exp_month, exp_year, cvv, amount_usd) do
    with {:ok} <- validate_card(card_number, exp_month, exp_year, cvv),
         {:ok, token} <- tokenize_card(card_number, exp_month, exp_year, cvv) do
      payload = %{
        token: token,
        amount_cents: round(amount_usd * 100),
        currency: "USD",
        description: "Charge via CardProcessor"
      }

      Logger.info(
        "Charging #{mask_card_number(card_number)} " <>
          "#{exp_month}/#{exp_year} for $#{:erlang.float_to_binary(amount_usd, decimals: 2)}"
      )

      simulate_gateway_request(payload)
    end
  end

  @spec mask_card_number(String.t()) :: String.t()
  def mask_card_number(card_number) do
    digits = String.replace(card_number, ~r/\D/, "")
    last_four = String.slice(digits, -4, 4)
    masked = String.duplicate("*", String.length(digits) - 4)
    masked <> last_four
  end

  @spec detect_brand(String.t()) :: String.t()
  def detect_brand(card_number) do
    digits = String.replace(card_number, ~r/\D/, "")

    cond do
      String.starts_with?(digits, "4") -> "visa"
      String.starts_with?(digits, ["51", "52", "53", "54", "55"]) -> "mastercard"
      String.starts_with?(digits, ["34", "37"]) -> "amex"
      String.starts_with?(digits, "6011") -> "discover"
      true -> "unknown"
    end
  end

  defp check_card_number_format(card_number) do
    digits = String.replace(card_number, ~r/\D/, "")

    if String.length(digits) in 13..19 do
      :ok
    else
      {:error, "Card number has invalid length: #{String.length(digits)} digits"}
    end
  end

  defp check_luhn(card_number) do
    digits =
      card_number
      |> String.replace(~r/\D/, "")
      |> String.graphemes()
      |> Enum.map(&String.to_integer/1)
      |> Enum.reverse()

    sum =
      digits
      |> Enum.with_index()
      |> Enum.reduce(0, fn {digit, idx}, acc ->
        if rem(idx, 2) == 1 do
          doubled = digit * 2
          acc + if doubled > 9, do: doubled - 9, else: doubled
        else
          acc + digit
        end
      end)

    if rem(sum, 10) == 0, do: :ok, else: {:error, "Card number failed Luhn check"}
  end

  defp check_expiry(month, year) do
    now = Date.utc_today()
    exp_date = Date.new!(year, month, 1)

    if Date.compare(exp_date, Date.beginning_of_month(now)) != :lt do
      :ok
    else
      {:error, "Card expired: #{month}/#{year}"}
    end
  end

  defp check_cvv(cvv, "amex") do
    if String.match?(cvv, ~r/^\d{4}$/) do
      :ok
    else
      {:error, "Amex CVV must be 4 digits"}
    end
  end

  defp check_cvv(cvv, _brand) do
    if String.match?(cvv, ~r/^\d{3}$/) do
      :ok
    else
      {:error, "CVV must be 3 digits"}
    end
  end

  defp generate_token(card_number, exp_month, exp_year) do
    seed = "#{card_number}|#{exp_month}|#{exp_year}|#{System.monotonic_time()}"
    :crypto.hash(:sha256, seed) |> Base.encode16(case: :lower) |> String.slice(0, 32)
  end

  defp simulate_gateway_request(payload) do
    Logger.debug("Sending charge to #{@gateway_endpoint}: #{inspect(payload)}")
    {:ok, %{transaction_id: generate_token("txn", 0, 0), status: "approved", payload: payload}}
  end
end
```
