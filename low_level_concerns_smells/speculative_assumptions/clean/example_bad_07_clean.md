```elixir
defmodule Billing.InvoiceLineParser do
  @moduledoc """
  Parses structured line item descriptor strings used in the invoice generation pipeline.

  Expected format:
    "<product_code>|<qty>x<unit_price>|<tax_code>|<description>"

  Examples:
    "SAAS-PRO-SEATS|10x149.99|GST-AU|Professional SaaS Seats - Annual Subscription"
    "SUPPORT-PREMIER|1x2500.00|GST-AU|Premier Support Package - FY2024"
  """

  require Logger

  defstruct [
    :product_code,
    :quantity,
    :unit_price,
    :tax_code,
    :description,
    :subtotal,
    :tax_amount
  ]

  @default_tax_rate 0.10

  @doc """
  Parses a single raw line item string into a `Billing.InvoiceLineParser` struct.

  Raises `ArgumentError` if the quantity/price segment cannot be parsed.
  """

  def parse(raw_line_item) when is_binary(raw_line_item) do
    segments = String.split(raw_line_item, "|")

    product_code = Enum.at(segments, 0)
    qty_price    = Enum.at(segments, 1)
    tax_code     = Enum.at(segments, 2)
    description  = Enum.at(segments, 3)

    {quantity, unit_price} = parse_qty_price(qty_price)

    tax_rate   = resolve_tax_rate(tax_code)
    subtotal   = quantity * unit_price
    tax_amount = Float.round(subtotal * tax_rate, 2)

    %__MODULE__{
      product_code: product_code,
      quantity:     quantity,
      unit_price:   unit_price,
      tax_code:     tax_code,
      description:  description,
      subtotal:     Float.round(subtotal, 2),
      tax_amount:   tax_amount
    }
  end

  @doc """
  Parses a list of raw line item strings and returns a list of structs.
  Logs and skips any entry that raises during parsing.
  """
  def parse_batch(raw_lines) when is_list(raw_lines) do
    Enum.reduce(raw_lines, [], fn raw, acc ->
      try do
        [parse(raw) | acc]
      rescue
        e ->
          Logger.warning("InvoiceLineParser: skipping malformed line item — #{inspect(e)}")
          acc
      end
    end)
    |> Enum.reverse()
  end

  @doc """
  Computes invoice totals from a list of parsed line item structs.
  """
  def compute_totals(items) when is_list(items) do
    Enum.reduce(items, %{subtotal: 0.0, tax: 0.0, grand_total: 0.0}, fn item, acc ->
      %{
        subtotal:    Float.round(acc.subtotal    + item.subtotal, 2),
        tax:         Float.round(acc.tax         + item.tax_amount, 2),
        grand_total: Float.round(acc.grand_total + item.subtotal + item.tax_amount, 2)
      }
    end)
  end

  @doc """
  Formats a parsed line item for inclusion in a human-readable invoice preview.
  """
  def format_for_display(%__MODULE__{} = item) do
    """
    [#{item.product_code}] #{item.description}
      Quantity : #{item.quantity} × $#{:erlang.float_to_binary(item.unit_price, [{:decimals, 2}])}
      Subtotal : $#{:erlang.float_to_binary(item.subtotal, [{:decimals, 2}])}
      Tax (#{item.tax_code}) : $#{:erlang.float_to_binary(item.tax_amount, [{:decimals, 2}])}
    """
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp parse_qty_price(segment) when is_binary(segment) do
    case String.split(segment, "x") do
      [qty_str, price_str] ->
        quantity   = String.to_integer(String.trim(qty_str))
        unit_price = parse_float(String.trim(price_str))
        {quantity, unit_price}

      _ ->
        raise ArgumentError, "Unexpected qty×price format: #{inspect(segment)}"
    end
  end

  defp parse_float(str) do
    case Float.parse(str) do
      {val, ""} -> val
      _         -> raise ArgumentError, "Cannot parse float from: #{inspect(str)}"
    end
  end

  defp resolve_tax_rate("GST-AU"),  do: 0.10
  defp resolve_tax_rate("VAT-GB"),  do: 0.20
  defp resolve_tax_rate("VAT-DE"),  do: 0.19
  defp resolve_tax_rate("HST-CA"),  do: 0.13
  defp resolve_tax_rate(_unknown),  do: @default_tax_rate
end
```
