# Annotated Example — Speculative Assumptions

## Metadata

- **Smell name:** Speculative Assumptions
- **Expected smell location:** `parse_amount/1` function, lines ~30–40
- **Affected function(s):** `parse_amount/1`
- **Short explanation:** `parse_amount/1` silently falls back to `0.0` when the string cannot be parsed as a valid monetary amount. Instead of crashing on unexpected input, it returns a plausible-looking but incorrect value, hiding errors from the caller and upstream billing logic.

---

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

  # VALIDATION: SMELL START - Speculative Assumptions
  # VALIDATION: This is a smell because `parse_amount/1` does not use pattern
  # matching or strict validation to ensure the input conforms to an expected
  # format. Instead of crashing on an unexpected value (e.g. "N/A", "$1.234,56",
  # or nil), it makes a speculative assumption that stripping non-numeric
  # characters and calling `Float.parse/1` will always produce a meaningful
  # result. When `Float.parse/1` fails, it silently returns `0.0`, which is a
  # valid-looking monetary amount that will be persisted and used in downstream
  # calculations without any indication that the input was invalid.
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
  # VALIDATION: SMELL END

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
