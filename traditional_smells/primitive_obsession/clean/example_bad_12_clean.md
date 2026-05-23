```elixir
defmodule Payments.CurrencyConverter do
  @moduledoc """
  Converts monetary amounts between currencies using mid-market rates
  with configurable spread. Produces a full conversion receipt for
  compliance and audit logging.
  """

  require Logger

  @max_rate_age_seconds 300
  @default_spread 0.015
  @supported_currencies ~w(USD EUR GBP JPY BRL CAD AUD CHF SEK NOK)

  @spec convert(float(), String.t(), String.t(), float()) ::
          {:ok, float()} | {:error, String.t()}
  def convert(amount, from_currency, to_currency, rate)
      when is_float(amount) and is_binary(from_currency) and is_binary(to_currency) and
             is_float(rate) do
    with :ok <- validate_currency(from_currency),
         :ok <- validate_currency(to_currency),
         :ok <- validate_rate(rate) do
      converted = Float.round(amount * rate, 2)
      Logger.debug("Converted #{amount} #{from_currency} → #{converted} #{to_currency} at #{rate}")
      {:ok, converted}
    end
  end

  @spec apply_spread(float(), String.t(), float()) ::
          {:ok, float()} | {:error, String.t()}
  def apply_spread(rate, direction, spread \\ @default_spread) do
    with :ok <- validate_rate(rate) do
      adjusted =
        case direction do
          "buy" -> Float.round(rate * (1.0 - spread), 6)
          "sell" -> Float.round(rate * (1.0 + spread), 6)
          _ -> {:error, "Unknown direction '#{direction}', expected 'buy' or 'sell'"}
        end

      case adjusted do
        {:error, _} = err -> err
        rate_value -> {:ok, rate_value}
      end
    end
  end

  @spec effective_rate(String.t(), String.t(), float()) ::
          {:ok, float()} | {:error, String.t()}
  def effective_rate(from_currency, to_currency, mid_rate) do
    with :ok <- validate_currency(from_currency),
         :ok <- validate_currency(to_currency),
         :ok <- validate_rate(mid_rate),
         {:ok, sell_rate} <- apply_spread(mid_rate, "sell") do
      Logger.debug(
        "Effective rate #{from_currency}/#{to_currency}: mid=#{mid_rate}, sell=#{sell_rate}"
      )

      {:ok, sell_rate}
    end
  end

  @spec build_conversion_receipt(float(), String.t(), String.t(), float(), DateTime.t()) ::
          map()
  def build_conversion_receipt(amount, from_currency, to_currency, rate, rate_timestamp) do
    age_seconds = DateTime.diff(DateTime.utc_now(), rate_timestamp, :second)
    stale = age_seconds > @max_rate_age_seconds

    converted_amount = Float.round(amount * rate, 2)

    %{
      receipt_id: generate_receipt_id(),
      from: %{amount: amount, currency: from_currency},
      to: %{amount: converted_amount, currency: to_currency},
      rate: rate,
      rate_fetched_at: rate_timestamp,
      rate_age_seconds: age_seconds,
      rate_stale: stale,
      created_at: DateTime.utc_now()
    }
  end

  @spec invert_rate(float()) :: {:ok, float()} | {:error, String.t()}
  def invert_rate(rate) do
    if rate > 0.0 do
      {:ok, Float.round(1.0 / rate, 6)}
    else
      {:error, "Rate must be positive to invert, got #{rate}"}
    end
  end

  defp validate_currency(currency) do
    if String.upcase(currency) in @supported_currencies do
      :ok
    else
      {:error,
       "Unsupported currency '#{currency}'. Supported: #{Enum.join(@supported_currencies, ", ")}"}
    end
  end

  defp validate_rate(rate) do
    cond do
      rate <= 0.0 -> {:error, "Exchange rate must be positive, got #{rate}"}
      rate > 100_000.0 -> {:error, "Exchange rate #{rate} seems implausibly large"}
      true -> :ok
    end
  end

  defp generate_receipt_id do
    :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
  end
end
```
