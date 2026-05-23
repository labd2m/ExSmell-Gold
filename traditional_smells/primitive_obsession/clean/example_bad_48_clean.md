```elixir
defmodule Payments.CardProcessor do
  @moduledoc """
  Handles credit and debit card charge operations for the payment gateway.
  Performs card validation, network detection, and gateway submission.
  """

  require Logger
  alias Payments.{GatewayClient, AuditLog, FraudDetector}

  @luhn_modulus 10
  @supported_networks ["visa", "mastercard", "amex", "discover", "elo"]
  @max_charge_amount 50_000.00

  @spec charge_card(String.t(), integer(), integer(), String.t(), float()) ::
          {:ok, map()} | {:error, String.t()}
  def charge_card(card_number, expiry_month, expiry_year, cvv, amount)
      when is_binary(card_number) and is_integer(expiry_month) and
             is_integer(expiry_year) and is_binary(cvv) and is_float(amount) do
    with :ok <- validate_card(card_number, expiry_month, expiry_year, cvv),
         :ok <- validate_amount(amount),
         {:ok, network} <- determine_card_network(card_number),
         :ok <- FraudDetector.check(card_number, amount) do
      masked = mask_card_number(card_number)

      payload = %{
        card_number: card_number,
        expiry_month: expiry_month,
        expiry_year: expiry_year,
        cvv: cvv,
        amount: amount,
        network: network
      }

      case GatewayClient.submit(payload) do
        {:ok, txn_id} ->
          AuditLog.record(:charge, %{
            masked_card: masked,
            network: network,
            amount: amount,
            txn_id: txn_id
          })

          Logger.info("Charged #{masked} (#{network}) — amount: #{amount}, txn: #{txn_id}")
          {:ok, %{transaction_id: txn_id, masked_card: masked, network: network, amount: amount}}

        {:error, :declined} ->
          {:error, "card_declined"}

        {:error, reason} ->
          Logger.warning("Gateway error for #{masked}: #{reason}")
          {:error, "gateway_error"}
      end
    end
  end

  def charge_card(_, _, _, _, _), do: {:error, "invalid_arguments"}

  @spec validate_card(String.t(), integer(), integer(), String.t()) ::
          :ok | {:error, String.t()}
  def validate_card(card_number, expiry_month, expiry_year, cvv) do
    sanitised = String.replace(card_number, ~r/\s/, "")
    current_year = Date.utc_today().year
    current_month = Date.utc_today().month

    cond do
      not Regex.match?(~r/^\d{13,19}$/, sanitised) ->
        {:error, "invalid_card_number_format"}

      not luhn_valid?(sanitised) ->
        {:error, "card_number_failed_luhn_check"}

      expiry_month < 1 or expiry_month > 12 ->
        {:error, "invalid_expiry_month"}

      expiry_year < current_year or
          (expiry_year == current_year and expiry_month < current_month) ->
        {:error, "card_expired"}

      not Regex.match?(~r/^\d{3,4}$/, cvv) ->
        {:error, "invalid_cvv"}

      true ->
        :ok
    end
  end

  @spec mask_card_number(String.t()) :: String.t()
  def mask_card_number(card_number) do
    sanitised = String.replace(card_number, ~r/\s/, "")
    last4 = String.slice(sanitised, -4, 4)
    String.duplicate("*", String.length(sanitised) - 4) <> last4
  end

  @spec determine_card_network(String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def determine_card_network(card_number) do
    sanitised = String.replace(card_number, ~r/\s/, "")

    network =
      cond do
        Regex.match?(~r/^4/, sanitised) -> "visa"
        Regex.match?(~r/^5[1-5]/, sanitised) -> "mastercard"
        Regex.match?(~r/^3[47]/, sanitised) -> "amex"
        Regex.match?(~r/^6(?:011|5)/, sanitised) -> "discover"
        Regex.match?(~r/^(?:4011|4312|4389|6362)/, sanitised) -> "elo"
        true -> "unknown"
      end

    if network in @supported_networks do
      {:ok, network}
    else
      {:error, "unsupported_card_network"}
    end
  end

  defp validate_amount(amount) when amount > 0.0 and amount <= @max_charge_amount, do: :ok
  defp validate_amount(amount) when amount <= 0.0, do: {:error, "amount_must_be_positive"}
  defp validate_amount(_), do: {:error, "amount_exceeds_limit"}

  defp luhn_valid?(number) do
    number
    |> String.graphemes()
    |> Enum.map(&String.to_integer/1)
    |> Enum.reverse()
    |> Enum.with_index()
    |> Enum.reduce(0, fn {digit, idx}, acc ->
      if rem(idx, 2) == 1 do
        doubled = digit * 2
        acc + if(doubled > 9, do: doubled - 9, else: doubled)
      else
        acc + digit
      end
    end)
    |> rem(@luhn_modulus) == 0
  end
end
```
