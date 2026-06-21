# Annotated Example — Bad Code

- **Smell name:** Using App Configuration for libraries
- **Expected smell location:** `CurrencyFormatter.format/1`
- **Affected function(s):** `format/1`, `format_range/2`, `parse/1`
- **Short explanation:** The library reads `:currency`, `:locale`, `:decimal_places`, and `:symbol_position` from the global `Application` environment. A dependent application cannot format prices in multiple currencies or locales simultaneously (e.g., showing USD for US users and EUR for European users) without modifying the global configuration at runtime.

```elixir
defmodule CurrencyFormatter do
  @moduledoc """
  A library for formatting and parsing monetary amounts.

  Provides locale-aware currency formatting including symbol placement,
  thousands separators, and decimal precision.

  Application configuration:

      config :currency_formatter,
        currency:         "USD",
        locale:           "en_US",
        decimal_places:   2,
        symbol_position:  :before,   # :before | :after
        thousands_sep:    ",",
        decimal_sep:      ".",
        negative_format:  :parentheses  # :parentheses | :minus
  """

  @currency_symbols %{
    "USD" => "$",
    "EUR" => "€",
    "GBP" => "£",
    "JPY" => "¥",
    "BRL" => "R$",
    "CAD" => "CA$",
    "AUD" => "A$",
    "CHF" => "Fr."
  }

  @doc """
  Formats an integer amount (in the smallest currency unit, e.g. cents) as a
  human-readable currency string.

  ## Example

      iex> CurrencyFormatter.format(1999)
      "$19.99"
  """
  # VALIDATION: SMELL START - Using App Configuration for libraries
  # VALIDATION: This is a smell because currency, locale, decimal_places,
  # symbol_position, thousands_sep, decimal_sep, and negative_format are all
  # read from Application.fetch_env!/2 instead of being function parameters,
  # making it impossible for a multi-currency application to call format/1
  # for different currencies without globally mutating the app config.
  def format(amount_cents) when is_integer(amount_cents) do
    currency        = Application.fetch_env!(:currency_formatter, :currency)
    decimal_places  = Application.fetch_env!(:currency_formatter, :decimal_places)
    symbol_position = Application.fetch_env!(:currency_formatter, :symbol_position)
    thousands_sep   = Application.fetch_env!(:currency_formatter, :thousands_sep)
    decimal_sep     = Application.fetch_env!(:currency_formatter, :decimal_sep)
    negative_format = Application.fetch_env!(:currency_formatter, :negative_format)
  # VALIDATION: SMELL END

    symbol     = Map.get(@currency_symbols, currency, currency)
    is_negative = amount_cents < 0
    abs_cents  = abs(amount_cents)

    factor     = trunc(:math.pow(10, decimal_places))
    whole      = div(abs_cents, factor)
    fractional = rem(abs_cents, factor)

    whole_str      = whole |> Integer.to_string() |> insert_thousands_sep(thousands_sep)
    fractional_str = fractional |> Integer.to_string() |> String.pad_leading(decimal_places, "0")

    number_str =
      if decimal_places > 0 do
        "#{whole_str}#{decimal_sep}#{fractional_str}"
      else
        whole_str
      end

    formatted =
      case symbol_position do
        :before -> "#{symbol}#{number_str}"
        :after  -> "#{number_str} #{symbol}"
      end

    if is_negative do
      case negative_format do
        :parentheses -> "(#{formatted})"
        :minus       -> "-#{formatted}"
      end
    else
      formatted
    end
  end

  @doc """
  Formats a float amount (in major currency units) as a currency string.
  """
  def format_float(amount) when is_float(amount) do
    decimal_places = Application.fetch_env!(:currency_formatter, :decimal_places)
    factor         = trunc(:math.pow(10, decimal_places))
    format(round(amount * factor))
  end

  @doc """
  Formats a price range as a string, e.g., "$10.00 – $25.00".
  """
  def format_range(min_cents, max_cents)
      when is_integer(min_cents) and is_integer(max_cents) do
    "#{format(min_cents)} – #{format(max_cents)}"
  end

  @doc """
  Parses a formatted currency string back to integer cents.

  Returns `{:ok, cents}` or `{:error, :invalid_format}`.
  """
  def parse(string) when is_binary(string) do
    decimal_places = Application.fetch_env!(:currency_formatter, :decimal_places)
    currency       = Application.fetch_env!(:currency_formatter, :currency)
    symbol         = Map.get(@currency_symbols, currency, currency)

    cleaned =
      string
      |> String.replace(symbol, "")
      |> String.replace(",", "")
      |> String.replace("(", "-")
      |> String.replace(")", "")
      |> String.trim()

    case Float.parse(cleaned) do
      {value, ""} ->
        factor = trunc(:math.pow(10, decimal_places))
        {:ok, round(value * factor)}

      _ ->
        {:error, :invalid_format}
    end
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp insert_thousands_sep(str, sep) do
    str
    |> String.graphemes()
    |> Enum.reverse()
    |> Enum.chunk_every(3)
    |> Enum.join(sep)
    |> String.graphemes()
    |> Enum.reverse()
    |> Enum.join()
  end
end
```
