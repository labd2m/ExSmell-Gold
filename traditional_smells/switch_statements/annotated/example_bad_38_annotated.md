# Annotated Example — Switch Statements

## Metadata

- **Smell name:** Switch Statements
- **Expected smell location:** `CurrencyFormatter.minor_unit_factor/1` and `CurrencyFormatter.symbol/1`
- **Affected functions:** `minor_unit_factor/1`, `symbol/1`
- **Short explanation:** The same `case` branching over currency code (`:usd`, `:eur`, `:gbp`, `:jpy`, `:brl`) is duplicated in `minor_unit_factor/1` and `symbol/1`. Adding a new currency requires updating both case expressions.

---

```elixir
defmodule CurrencyFormatter do
  @moduledoc """
  Handles currency formatting, minor-unit conversion, and
  symbol resolution for a multi-currency payment platform
  that stores all monetary amounts as integer minor units.
  """

  alias CurrencyFormatter.{Money, Locale}

  @type currency_code :: :usd | :eur | :gbp | :jpy | :brl

  @spec format(Money.t(), Locale.t()) :: String.t()
  def format(%Money{amount: amount, currency: currency}, %Locale{} = locale) do
    factor = minor_unit_factor(currency)
    major = amount / factor
    formatted_number = :io_lib.format("~.#{decimal_places(factor)}f", [major]) |> IO.iodata_to_binary()
    currency_symbol = symbol(currency)

    case locale.symbol_position do
      :before -> "#{currency_symbol}#{formatted_number}"
      :after  -> "#{formatted_number} #{currency_symbol}"
    end
  end

  @spec to_minor_units(float(), currency_code()) :: integer()
  def to_minor_units(amount, currency) do
    factor = minor_unit_factor(currency)
    round(amount * factor)
  end

  @spec from_minor_units(integer(), currency_code()) :: float()
  def from_minor_units(amount_in_minor, currency) do
    factor = minor_unit_factor(currency)
    amount_in_minor / factor
  end

  @spec add(Money.t(), Money.t()) :: {:ok, Money.t()} | {:error, String.t()}
  def add(%Money{currency: c} = a, %Money{currency: c} = b) do
    {:ok, %Money{amount: a.amount + b.amount, currency: c}}
  end

  def add(%Money{currency: a_c}, %Money{currency: b_c}) do
    {:error, "currency mismatch: #{a_c} vs #{b_c}"}
  end

  # VALIDATION: SMELL START - Switch Statements
  # VALIDATION: This is a smell because the same case branching on `currency`
  # also appears in `symbol/1` below. Both enumerate :usd, :eur, :gbp, :jpy,
  # :brl — adding a new currency requires updating both case blocks.
  @spec minor_unit_factor(currency_code()) :: integer()
  def minor_unit_factor(currency) do
    case currency do
      :usd -> 100
      :eur -> 100
      :gbp -> 100
      :jpy -> 1
      :brl -> 100
    end
  end
  # VALIDATION: SMELL END

  # VALIDATION: SMELL START - Switch Statements
  # VALIDATION: This is a smell because the same case branching on `currency`
  # already appeared in `minor_unit_factor/1` above. All currency atoms are
  # repeated here, requiring parallel maintenance whenever currencies are added.
  @spec symbol(currency_code()) :: String.t()
  def symbol(currency) do
    case currency do
      :usd -> "$"
      :eur -> "€"
      :gbp -> "£"
      :jpy -> "¥"
      :brl -> "R$"
    end
  end
  # VALIDATION: SMELL END

  @spec zero(currency_code()) :: Money.t()
  def zero(currency), do: %Money{amount: 0, currency: currency}

  @spec supported_currencies() :: [currency_code()]
  def supported_currencies, do: [:usd, :eur, :gbp, :jpy, :brl]

  @spec decimal_places(integer()) :: integer()
  defp decimal_places(1), do: 0
  defp decimal_places(_), do: 2
end
```
