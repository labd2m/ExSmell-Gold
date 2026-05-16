```elixir
defmodule MyApp.Finance.CurrencyConverter do
  @moduledoc """
  Converts monetary amounts between currencies using live and cached
  exchange rates. Supports mid-market, buy, and sell rate types with
  configurable spread adjustments and rate staleness thresholds.
  """

  require Logger

  alias MyApp.Finance.{RateProvider, RateCache, ConversionLog, SpreadEngine}

  @staleness_threshold_seconds 300
  @rounding_precision 4
  @spread_default 0.0025
  @supported_rate_types [:mid, :buy, :sell]

  @type conversion_opts :: [
          rate_type: atom(),
          spread_override: number() | nil,
          use_cached: boolean(),
          log_conversion: boolean()
        ]

  @spec convert(number(), String.t(), String.t(), conversion_opts()) ::
          {:ok, map()} | {:error, atom()}
  def convert(amount, from_currency, to_currency, opts \\ []) do
    rate_type = Keyword.get(opts, :rate_type, :mid)
    spread_override = Keyword.get(opts, :spread_override)
    use_cached = Keyword.get(opts, :use_cached, true)
    log_conversion = Keyword.get(opts, :log_conversion, true)

    with :ok <- validate_currencies(from_currency, to_currency),
         :ok <- validate_rate_type(rate_type) do

      if from_currency == to_currency do
        {:ok, %{amount: amount, from: from_currency, to: to_currency, rate: 1.0, converted: amount}}
      else
        with {:ok, exchange_rate, rate_fetched_at} <-
               fetch_rate(from_currency, to_currency, rate_type, use_cached),
             :ok <- check_rate_freshness(rate_fetched_at) do

          spread = spread_override || SpreadEngine.spread(from_currency, to_currency) || @spread_default
          adjusted_rate = apply_spread(exchange_rate, rate_type, spread)

          converted =
            Decimal.new(amount)
            |> Decimal.mult(Decimal.new(to_string(adjusted_rate)))
            |> Decimal.round(@rounding_precision)

          result = %{
            amount: amount,
            from_currency: from_currency,
            to_currency: to_currency,
            exchange_rate: exchange_rate,
            adjusted_rate: adjusted_rate,
            spread: spread,
            converted_amount: converted,
            rate_type: rate_type,
            rate_fetched_at: rate_fetched_at,
            converted_at: DateTime.utc_now()
          }

          if log_conversion do
            ConversionLog.record(result)
          end

          Logger.debug(
            "Currency converted: #{amount} #{from_currency} -> #{converted} #{to_currency} " <>
              "rate=#{adjusted_rate}"
          )

          {:ok, result}
        end
      end
    end
  end

  @spec batch_convert([map()], String.t(), conversion_opts()) :: {:ok, [map()]}
  def batch_convert(amounts_with_currencies, target_currency, opts \\ []) do
    results =
      Enum.map(amounts_with_currencies, fn %{amount: amount, currency: currency} ->
        case convert(amount, currency, target_currency, opts) do
          {:ok, result} -> result
          {:error, reason} -> %{error: reason, amount: amount, currency: currency}
        end
      end)

    {:ok, results}
  end

  @spec rate(String.t(), String.t(), atom()) :: {:ok, number()} | {:error, atom()}
  def rate(from_currency, to_currency, rate_type \\ :mid) do
    with {:ok, rate, _fetched_at} <- fetch_rate(from_currency, to_currency, rate_type, true) do
      {:ok, rate}
    end
  end

  # Private helpers

  defp validate_currencies(from, to) when is_binary(from) and is_binary(to) and
                                            byte_size(from) == 3 and byte_size(to) == 3, do: :ok
  defp validate_currencies(_, _), do: {:error, :invalid_currency_code}

  defp validate_rate_type(type) when type in @supported_rate_types, do: :ok
  defp validate_rate_type(_), do: {:error, :invalid_rate_type}

  defp fetch_rate(from, to, rate_type, true) do
    case RateCache.get(from, to, rate_type) do
      {:ok, rate, fetched_at} -> {:ok, rate, fetched_at}
      _ -> fetch_rate(from, to, rate_type, false)
    end
  end

  defp fetch_rate(from, to, rate_type, false) do
    with {:ok, rate} <- RateProvider.fetch(from, to, rate_type) do
      RateCache.put(from, to, rate_type, rate)
      {:ok, rate, DateTime.utc_now()}
    end
  end

  defp check_rate_freshness(fetched_at) do
    age = DateTime.diff(DateTime.utc_now(), fetched_at)
    if age <= @staleness_threshold_seconds, do: :ok, else: {:error, :stale_rate}
  end

  defp apply_spread(rate, :buy, spread), do: rate * (1 - spread)
  defp apply_spread(rate, :sell, spread), do: rate * (1 + spread)
  defp apply_spread(rate, :mid, _spread), do: rate
end
```
