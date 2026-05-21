```elixir
defmodule Tax.CodeFormatter do
  @moduledoc """
  Formats tax code entries for inclusion in invoices, tax declarations,
  and regulatory filings. Handles VAT, withholding tax, and sales tax codes
  across multiple jurisdictions.
  """

  @code_prefix "TX"
  @rate_decimal_places 2
  @jurisdiction_separator "/"

  @doc """
  Formats a collection of tax entries into a list of labeled strings
  suitable for display in an invoice summary.
  """
  def format_tax_summary(entries) when is_list(entries) do
    entries
    |> Enum.map(&format_tax_line/1)
    |> Enum.join("\n")
  end

  @doc """
  Formats a single tax entry map into a display string.
  Expected fields: `:code`, `:description`, `:rate`, `:amount_cents`.
  """
  def format_tax_line(%{code: code, description: desc, rate: rate, amount_cents: amount})
      when is_binary(desc) and is_number(rate) and is_integer(amount) do
    formatted_rate = :erlang.float_to_binary(rate / 1, decimals: @rate_decimal_places)
    formatted_amount = format_cents(amount)
    "#{@code_prefix}-#{to_string(code)} #{desc} #{formatted_rate}% — #{formatted_amount}"
  end

  @doc """
  Builds a qualified tax code string with jurisdiction prefix.
  """
  def qualify_code(jurisdiction, code)
      when is_binary(jurisdiction) and is_binary(code) do
    "#{String.upcase(jurisdiction)}#{@jurisdiction_separator}#{code}"
  end

  @doc """
  Returns the applicable tax rate for a product category and jurisdiction.
  This is a stub; real implementations would query a rate table.
  """
  def rate_for(category, jurisdiction)
      when is_atom(category) and is_binary(jurisdiction) do
    case {category, String.upcase(jurisdiction)} do
      {:food, "BR"} -> {:ok, 0.0}
      {:electronics, "BR"} -> {:ok, 0.12}
      {:services, "BR"} -> {:ok, 0.05}
      {:food, "US"} -> {:ok, 0.0}
      {:electronics, "US"} -> {:ok, 0.08}
      _ -> {:error, :rate_not_found}
    end
  end

  @doc """
  Computes the tax amount in cents given a base amount and rate.
  """
  def compute_tax(base_cents, rate)
      when is_integer(base_cents) and is_float(rate) and rate >= 0.0 do
    trunc(base_cents * rate)
  end

  @doc """
  Returns whether a given tax code string appears valid.
  """
  def valid_code?(code) when is_binary(code) do
    Regex.match?(~r/^[A-Z0-9]{3,12}$/, code)
  end

  def valid_code?(_), do: false

  @doc """
  Formats a cent amount as a currency string.
  """
  def format_cents(cents) when is_integer(cents) do
    units = div(abs(cents), 100)
    remainder = rem(abs(cents), 100)
    sign = if cents < 0, do: "-", else: ""
    "#{sign}#{units}.#{String.pad_leading("#{remainder}", 2, "0")}"
  end
end
```
