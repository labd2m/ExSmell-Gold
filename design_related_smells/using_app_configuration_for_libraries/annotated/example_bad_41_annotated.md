# Code Smell Example – Annotated

- **Smell name:** Using App Configuration for libraries
- **Expected smell location:** `MoneyFormatter.format/1`
- **Affected function(s):** `format/1`, `format_range/2`
- **Short explanation:** The library reads `:currency_symbol`, `:decimal_separator`, `:thousands_separator`, and `:symbol_position` from the global `Application Environment` instead of accepting them as parameters. Applications that need to display prices in multiple currencies or locales (e.g., USD for US users and EUR for EU users) cannot do so without changing global config, defeating the purpose of a reusable formatter library.

```elixir
defmodule MoneyFormatter do
  @moduledoc """
  A library for formatting monetary values into human-readable strings.
  Handles symbol placement, thousands grouping, and decimal precision
  for use in invoices, receipts, and financial dashboards.

  Configuration (config/config.exs):

      config :money_formatter,
        currency_symbol: "$",
        decimal_separator: ".",
        thousands_separator: ",",
        symbol_position: :before,
        decimal_places: 2
  """

  @doc """
  Formats an integer or float amount (in the smallest currency unit or as
  a decimal) into a display string using the globally configured locale settings.

  ## Examples

      iex> MoneyFormatter.format(1_234_567)
      "$12,345.67"
  """
  @spec format(integer() | float()) :: String.t()
  def format(amount) when is_number(amount) do
    # VALIDATION: SMELL START - Using App Configuration for libraries
    # VALIDATION: This is a smell because the library fetches formatting options
    # (:currency_symbol, :decimal_separator, :thousands_separator,
    # :symbol_position, :decimal_places) from the global Application Environment
    # instead of accepting a locale/options parameter at the call site. An
    # application serving multiple markets cannot render "$1,234.56" for US
    # users and "€1.234,56" for EU users using the same function without a
    # global config swap, making the library unsuitable for multi-locale use.
    symbol = Application.fetch_env!(:money_formatter, :currency_symbol)
    decimal_sep = Application.fetch_env!(:money_formatter, :decimal_separator)
    thousands_sep = Application.fetch_env!(:money_formatter, :thousands_separator)
    position = Application.fetch_env!(:money_formatter, :symbol_position)
    decimal_places = Application.fetch_env!(:money_formatter, :decimal_places)
    # VALIDATION: SMELL END

    normalized = normalize_amount(amount)
    formatted_number = format_number(normalized, decimal_sep, thousands_sep, decimal_places)

    case position do
      :before -> "#{symbol}#{formatted_number}"
      :after -> "#{formatted_number} #{symbol}"
      _ -> "#{symbol}#{formatted_number}"
    end
  end

  @doc """
  Formats two amounts as a price range (e.g., "$10.00 – $50.00").
  """
  @spec format_range(number(), number()) :: String.t()
  def format_range(min_amount, max_amount)
      when is_number(min_amount) and is_number(max_amount) do
    "#{format(min_amount)} – #{format(max_amount)}"
  end

  @doc """
  Parses a formatted money string back into a float.
  Returns `{:ok, float}` or `{:error, reason}`.
  """
  @spec parse(String.t()) :: {:ok, float()} | {:error, String.t()}
  def parse(value) when is_binary(value) do
    cleaned =
      value
      |> String.replace(~r/[^\d.,\-]/, "")
      |> String.replace(",", "")

    case Float.parse(cleaned) do
      {amount, ""} -> {:ok, amount}
      {amount, _rest} -> {:ok, amount}
      :error -> {:error, "Could not parse '#{value}' as a monetary amount"}
    end
  end

  @doc """
  Returns true if the amount is negative.
  """
  @spec negative?(number()) :: boolean()
  def negative?(amount) when is_number(amount), do: amount < 0

  @doc """
  Returns the absolute value of a monetary amount.
  """
  @spec abs_amount(number()) :: number()
  def abs_amount(amount) when is_number(amount), do: abs(amount)

  @doc """
  Sums a list of monetary amounts and returns the formatted result.
  """
  @spec sum_and_format(list(number())) :: String.t()
  def sum_and_format(amounts) when is_list(amounts) do
    total = Enum.sum(amounts)
    format(total)
  end

  # --- Private helpers ---

  defp normalize_amount(amount) when is_integer(amount) do
    amount / 100.0
  end

  defp normalize_amount(amount) when is_float(amount), do: amount

  defp format_number(amount, decimal_sep, thousands_sep, decimal_places) do
    sign = if amount < 0, do: "-", else: ""
    abs_val = abs(amount)

    multiplier = :math.pow(10, decimal_places) |> round()
    rounded = round(abs_val * multiplier) / multiplier

    integer_part = trunc(rounded)
    frac_part = round((rounded - integer_part) * multiplier)

    integer_str = integer_part |> to_string() |> add_thousands_sep(thousands_sep)
    frac_str = frac_part |> to_string() |> String.pad_leading(decimal_places, "0")

    "#{sign}#{integer_str}#{decimal_sep}#{frac_str}"
  end

  defp add_thousands_sep(str, sep) do
    str
    |> String.reverse()
    |> String.graphemes()
    |> Enum.chunk_every(3)
    |> Enum.join(sep)
    |> String.reverse()
  end
end
```
