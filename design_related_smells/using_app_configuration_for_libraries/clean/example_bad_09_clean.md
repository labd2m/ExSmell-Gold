```elixir
defmodule CurrencyConverter do
  @moduledoc """
  A currency conversion library that applies exchange rates and
  configurable rounding strategies. Used in payment, pricing,
  and financial reporting modules.
  """

  @supported_strategies ~w(round floor ceil)a

  defmodule ConversionResult do
    @enforce_keys [:amount, :from_currency, :to_currency, :rate, :converted_amount]
    defstruct [
      :amount,
      :from_currency,
      :to_currency,
      :rate,
      :converted_amount,
      :rounded_amount,
      :precision,
      :strategy
    ]
  end

  defmodule RateError do
    defexception [:message, :from, :to]
  end

  @doc """
  Converts `amount` from `from_currency` to `to_currency` using
  the provided exchange rates map.

  `rates` should be a map like `%{"USD" => 1.0, "EUR" => 0.91, "BRL" => 5.10}`,
  with all rates relative to a common base currency.
  """
  def convert(amount, from_currency, to_currency, rates) when is_number(amount) do
    strategy  = Application.fetch_env!(:currency_converter, :rounding_strategy)
    precision = Application.fetch_env!(:currency_converter, :decimal_precision)

    unless strategy in @supported_strategies do
      raise ArgumentError, "Unknown rounding strategy: #{strategy}"
    end

    with {:ok, from_rate} <- fetch_rate(rates, from_currency),
         {:ok, to_rate}   <- fetch_rate(rates, to_currency) do
      raw_converted = amount * (to_rate / from_rate)
      rounded       = apply_rounding(raw_converted, strategy, precision)

      result = %ConversionResult{
        amount:           amount,
        from_currency:    from_currency,
        to_currency:      to_currency,
        rate:             to_rate / from_rate,
        converted_amount: raw_converted,
        rounded_amount:   rounded,
        precision:        precision,
        strategy:         strategy
      }

      {:ok, result}
    end
  end

  @doc """
  Converts a list of amounts and returns the summed result.
  Useful for aggregating multi-line invoice totals.
  """
  def convert_sum(amounts, from_currency, to_currency, rates)
      when is_list(amounts) do
    results =
      Enum.map(amounts, fn amount ->
        case convert(amount, from_currency, to_currency, rates) do
          {:ok, r} -> r.rounded_amount
          {:error, e} -> raise e
        end
      end)

    {:ok, Enum.sum(results)}
  end

  @doc """
  Formats a conversion result into a human-readable string.
  """
  def format_result(%ConversionResult{} = result) do
    "#{result.amount} #{result.from_currency} → " <>
      "#{result.rounded_amount} #{result.to_currency} " <>
      "(rate: #{Float.round(result.rate, 6)})"
  end

  # --- Private helpers ---

  defp fetch_rate(rates, currency) do
    case Map.fetch(rates, currency) do
      {:ok, rate} when is_number(rate) -> {:ok, rate}
      :error -> {:error, %RateError{message: "No rate for #{currency}", from: nil, to: currency}}
    end
  end

  defp apply_rounding(amount, :round, precision) do
    Float.round(amount, precision)
  end

  defp apply_rounding(amount, :floor, precision) do
    factor = :math.pow(10, precision)
    Float.floor(amount * factor) / factor
  end

  defp apply_rounding(amount, :ceil, precision) do
    factor = :math.pow(10, precision)
    Float.ceil(amount * factor) / factor
  end
end
```
