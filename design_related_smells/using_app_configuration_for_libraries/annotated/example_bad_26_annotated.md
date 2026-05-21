# Annotated Example 26

## Metadata

- **Smell name:** Using App Configuration for libraries
- **Expected smell location:** `CurrencyFormatter.format/2`
- **Affected function(s):** `format/2`
- **Short explanation:** The library function `format/2` reads `:rounding_mode` and `:decimal_precision` from the `Application` environment. A payments application that handles multiple currencies (some with 2 decimal places like USD, some with 0 like JPY, some with 3 like KWD) cannot use this library flexibly because the precision is a single global setting, preventing correct per-currency formatting from the same library at the same time.

---

```elixir
defmodule CurrencyFormatter do
  @moduledoc """
  Library for formatting and rounding monetary amounts for display
  and persistence. Used in payment processing, financial reporting,
  and checkout UIs across e-commerce and fintech applications.
  """

  @supported_rounding_modes [:half_up, :half_down, :half_even, :ceiling, :floor]

  @currency_symbols %{
    "USD" => "$",
    "EUR" => "€",
    "GBP" => "£",
    "JPY" => "¥",
    "BRL" => "R$",
    "CHF" => "Fr",
    "CAD" => "CA$",
    "AUD" => "A$"
  }

  @type format_opts :: [
          show_symbol: boolean(),
          show_code: boolean(),
          thousands_separator: String.t()
        ]

  @doc """
  Formats a numeric amount as a currency string for a given ISO 4217
  currency code. The rounding mode and decimal precision are
  controlled via the application environment.
  """
  @spec format(number(), String.t(), format_opts()) :: String.t()
  def format(amount, currency_code, opts \\ [])
      when (is_float(amount) or is_integer(amount)) and is_binary(currency_code) do
    # VALIDATION: SMELL START - Using App Configuration for libraries
    # VALIDATION: This is a smell because format/3 is a library function that
    # fetches :rounding_mode and :decimal_precision from the Application environment
    # rather than accepting them as function parameters. A payments application
    # dealing with multiple currencies cannot correctly apply currency-specific
    # decimal rules (2 for USD, 0 for JPY, 3 for KWD) from the same call site
    # without changing global config between calls, making correct concurrent
    # multi-currency formatting impossible.
    rounding_mode = Application.fetch_env!(:currency_formatter, :rounding_mode)
    precision = Application.fetch_env!(:currency_formatter, :decimal_precision)
    # VALIDATION: SMELL END

    unless rounding_mode in @supported_rounding_modes do
      raise ArgumentError, "Unsupported rounding mode: #{rounding_mode}"
    end

    rounded = round_amount(amount, precision, rounding_mode)
    formatted_number = format_number(rounded, precision, Keyword.get(opts, :thousands_separator, ","))

    symbol = Map.get(@currency_symbols, String.upcase(currency_code), "")
    show_symbol = Keyword.get(opts, :show_symbol, true)
    show_code = Keyword.get(opts, :show_code, false)

    cond do
      show_symbol and show_code ->
        "#{symbol}#{formatted_number} #{String.upcase(currency_code)}"

      show_symbol ->
        "#{symbol}#{formatted_number}"

      show_code ->
        "#{formatted_number} #{String.upcase(currency_code)}"

      true ->
        formatted_number
    end
  end

  @doc "Parses a formatted currency string and returns the numeric amount."
  @spec parse(String.t()) :: {:ok, float()} | {:error, :invalid_format}
  def parse(formatted) when is_binary(formatted) do
    stripped =
      formatted
      |> String.replace(~r/[^0-9.\-]/, "")

    case Float.parse(stripped) do
      {amount, ""} -> {:ok, amount}
      {amount, _} -> {:ok, amount}
      :error -> {:error, :invalid_format}
    end
  end

  @doc "Returns the known symbol for a given ISO 4217 currency code."
  @spec symbol_for(String.t()) :: String.t() | nil
  def symbol_for(code) when is_binary(code) do
    Map.get(@currency_symbols, String.upcase(code))
  end

  @doc "Returns true if the given currency code is supported."
  @spec supported_currency?(String.t()) :: boolean()
  def supported_currency?(code) when is_binary(code) do
    Map.has_key?(@currency_symbols, String.upcase(code))
  end

  # --- Private helpers ---

  defp round_amount(amount, precision, :half_up) do
    factor = :math.pow(10, precision)
    Float.round(amount * 1.0, precision)
    |> then(fn _ -> Float.round(amount * 1.0, precision) end)
    |> then(fn v -> trunc(v * factor + 0.5) / factor end)
  end

  defp round_amount(amount, precision, :half_even), do: Float.round(amount * 1.0, precision)
  defp round_amount(amount, precision, :floor), do: Float.floor(amount * 1.0, precision)
  defp round_amount(amount, precision, :ceiling), do: Float.ceil(amount * 1.0, precision)
  defp round_amount(amount, precision, _), do: Float.round(amount * 1.0, precision)

  defp format_number(amount, precision, sep) do
    [integer_part, decimal_part] =
      amount
      |> :erlang.float_to_binary(decimals: precision)
      |> String.split(".")

    grouped =
      integer_part
      |> String.graphemes()
      |> Enum.reverse()
      |> Enum.chunk_every(3)
      |> Enum.join(sep)
      |> String.reverse()

    if precision > 0, do: "#{grouped}.#{decimal_part}", else: grouped
  end
end
```
