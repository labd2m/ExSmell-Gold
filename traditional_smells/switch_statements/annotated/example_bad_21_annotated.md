# Annotated Example — Switch Statements

## Metadata

- **Smell name:** Switch Statements
- **Expected smell location:** `CurrencyFormatter` module — functions `minor_unit_exponent/1`, `symbol/1`, and `format_amount/2`
- **Affected functions:** `minor_unit_exponent/1`, `symbol/1`, `format_amount/2`
- **Short explanation:** The same `case currency` branching over `:usd`, `:eur`, `:brl`, and `:jpy` is duplicated across three functions. Adding a new currency forces a developer to update every case block independently, which is the Switch Statements smell.

---

```elixir
defmodule CurrencyFormatter do
  @moduledoc """
  Handles currency-aware formatting, minor-unit conversion, and symbol
  resolution for the payments and invoicing platform. Supports a fixed
  set of currencies used across customer-facing billing surfaces.
  """

  require Logger

  @supported_currencies [:usd, :eur, :brl, :jpy]

  def supported_currencies, do: @supported_currencies

  # VALIDATION: SMELL START - Switch Statements
  # VALIDATION: This is a smell because the same case branching over currency
  # (:usd, :eur, :brl, :jpy) is duplicated in minor_unit_exponent/1, symbol/1,
  # and format_amount/2. Adding a new currency requires updating all three
  # case expressions independently.

  @doc """
  Returns the exponent of the minor unit for the given currency code.
  For example, USD has 2 (cents), JPY has 0 (no subunit).
  """
  def minor_unit_exponent(currency) do
    case currency do
      :usd -> 2
      :eur -> 2
      :brl -> 2
      :jpy -> 0
      _ -> 2
    end
  end

  @doc """
  Returns the commonly recognised symbol string for the given currency.
  """
  def symbol(currency) do
    case currency do
      :usd -> "$"
      :eur -> "€"
      :brl -> "R$"
      :jpy -> "¥"
      _ -> "?"
    end
  end

  @doc """
  Formats a raw integer amount (in the currency's smallest unit) as a
  human-readable string with the currency symbol, e.g. 1099 USD -> "$10.99".
  """
  def format_amount(currency, amount_minor) when is_integer(amount_minor) do
    divisor =
      case currency do
        :usd -> 100
        :eur -> 100
        :brl -> 100
        :jpy -> 1
        _ -> 100
      end

    formatted_number =
      if divisor == 1 do
        Integer.to_string(amount_minor)
      else
        whole = div(amount_minor, divisor)
        frac = abs(rem(amount_minor, divisor))
        "#{whole}.#{String.pad_leading(Integer.to_string(frac), 2, "0")}"
      end

    "#{symbol(currency)}#{formatted_number}"
  end

  # VALIDATION: SMELL END

  @doc """
  Converts a decimal amount (float) to the integer minor unit representation
  used internally by the payments engine.
  """
  def to_minor_units(currency, amount) when is_float(amount) or is_integer(amount) do
    exp = minor_unit_exponent(currency)
    multiplier = :math.pow(10, exp) |> round()
    round(amount * multiplier)
  end

  @doc """
  Converts an integer minor-unit amount back to a float decimal.
  """
  def from_minor_units(currency, amount_minor) when is_integer(amount_minor) do
    exp = minor_unit_exponent(currency)
    divisor = :math.pow(10, exp)
    Float.round(amount_minor / divisor, exp)
  end

  @doc """
  Validates that the provided currency atom is supported by the platform.
  """
  def validate_currency(currency) when currency in @supported_currencies, do: :ok
  def validate_currency(other), do: {:error, {:unsupported_currency, other}}

  @doc """
  Builds a complete money struct from a float and currency code, normalising
  the amount to minor units for safe arithmetic.
  """
  def build_money(currency, amount) do
    with :ok <- validate_currency(currency) do
      minor = to_minor_units(currency, amount)

      {:ok,
       %{
         currency: currency,
         amount_minor: minor,
         formatted: format_amount(currency, minor),
         symbol: symbol(currency),
         exponent: minor_unit_exponent(currency)
       }}
    end
  end

  @doc """
  Adds two money values of the same currency, returning a new money struct.
  """
  def add(%{currency: c, amount_minor: a}, %{currency: c, amount_minor: b}) do
    {:ok, money} = build_money(c, from_minor_units(c, a + b))
    {:ok, money}
  end

  def add(%{currency: c1}, %{currency: c2}) do
    {:error, {:currency_mismatch, c1, c2}}
  end

  @doc """
  Produces a line-item display string for use in invoice PDFs.
  """
  def invoice_line(currency, unit_price_minor, quantity) when is_integer(quantity) do
    total_minor = unit_price_minor * quantity
    unit_str = format_amount(currency, unit_price_minor)
    total_str = format_amount(currency, total_minor)
    "#{quantity} x #{unit_str} = #{total_str}"
  end
end
```
