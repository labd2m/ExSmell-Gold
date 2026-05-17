```elixir
defmodule Billing.InvoiceParser do
  @moduledoc """
  Parses raw invoice data received from an external accounting integration
  and converts it into internal billing structs ready for persistence.
  """

  require Logger

  alias Billing.Invoice
  alias Billing.LineItem

  @date_format "{YYYY}-{0M}-{0D}"

  @doc """
  Parses a raw map coming from the accounting webhook payload into
  an `Invoice` struct.
  """
  def parse_invoice(raw) do
    %Invoice{
      id:           Map.get(raw, "invoice_id"),
      customer_id:  Map.get(raw, "customer_id"),
      issued_at:    parse_date(Map.get(raw, "issued_at")),
      due_at:       parse_date(Map.get(raw, "due_at")),
      total:        parse_amount(Map.get(raw, "total")),
      tax:          parse_amount(Map.get(raw, "tax")),
      line_items:   parse_line_items(Map.get(raw, "items", []))
    }
  end

  @doc """
  Parses a monetary string such as "1,234.56" or "USD 1234.56" into
  a float representing the amount in the invoice's base currency.
  """

  def parse_amount(nil), do: 0.0
  def parse_amount(value) when is_float(value), do: value
  def parse_amount(value) when is_integer(value), do: value / 1

  def parse_amount(value) when is_binary(value) do
    cleaned =
      value
      |> String.replace(~r/[^\d.]/, "")

    case Float.parse(cleaned) do
      {amount, _} -> amount
      :error      -> 0.0
    end
  end

  @doc """
  Parses a date string in ISO 8601 format into an `Date` struct.
  Raises if the string is invalid.
  """
  def parse_date(nil), do: nil

  def parse_date(value) when is_binary(value) do
    case Timex.parse(value, @date_format) do
      {:ok, dt}       -> Timex.to_date(dt)
      {:error, reason} ->
        Logger.error("InvoiceParser: invalid date #{inspect(value)}: #{reason}")
        raise ArgumentError, "invalid date: #{inspect(value)}"
    end
  end

  @doc """
  Parses a list of raw line-item maps into `LineItem` structs.
  """
  def parse_line_items(items) when is_list(items) do
    Enum.map(items, &parse_line_item/1)
  end

  defp parse_line_item(raw) do
    %LineItem{
      description: Map.get(raw, "description", ""),
      quantity:    parse_quantity(Map.get(raw, "quantity")),
      unit_price:  parse_amount(Map.get(raw, "unit_price")),
      subtotal:    parse_amount(Map.get(raw, "subtotal"))
    }
  end

  defp parse_quantity(nil), do: 1
  defp parse_quantity(value) when is_integer(value) and value > 0, do: value

  defp parse_quantity(value) when is_binary(value) do
    case Integer.parse(value) do
      {qty, _} when qty > 0 -> qty
      _ ->
        raise ArgumentError, "invalid quantity: #{inspect(value)}"
    end
  end

  defp parse_quantity(value) do
    raise ArgumentError, "invalid quantity: #{inspect(value)}"
  end
end
```
