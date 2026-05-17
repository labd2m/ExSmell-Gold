# Annotated Example — Speculative Assumptions

## Metadata

- **Smell name:** Speculative Assumptions
- **Expected smell location:** `InvoiceParser.parse_line_item/1`, around the field extraction logic
- **Affected function(s):** `parse_line_item/1`
- **Short explanation:** The function splits a raw invoice line by comma and accesses positional fields using `Enum.at/2`, which always returns a value (or `nil`) regardless of whether the line has the expected structure. If the CSV format deviates (e.g., extra commas in a description, missing fields, or a different column order), the function silently extracts wrong values — an amount field might be read as a description, or `nil` is returned without a crash — giving a false impression that parsing succeeded.

---

```elixir
defmodule Billing.InvoiceParser do
  @moduledoc """
  Parses raw invoice export files from the ERP system into structured line items.
  Each line in the export follows the format:
    item_code,description,quantity,unit_price,discount,total
  """

  require Logger

  @expected_fields 6

  def parse_file(path) do
    path
    |> File.stream!()
    |> Stream.drop(1)
    |> Stream.map(&String.trim/1)
    |> Stream.reject(&(&1 == ""))
    |> Stream.map(&parse_line_item/1)
    |> Stream.reject(&is_nil/1)
    |> Enum.to_list()
  end

  # VALIDATION: SMELL START - Speculative Assumptions
  # VALIDATION: This is a smell because the function splits on "," and uses Enum.at/2
  # VALIDATION: with hardcoded positional indices to extract fields. If any field contains
  # VALIDATION: a comma (e.g., a description like "Laptop, 15 inch"), or if the ERP
  # VALIDATION: exports columns in a different order, the function silently reads the
  # VALIDATION: wrong values into the struct instead of crashing or returning an error.
  # VALIDATION: Enum.at/2 never raises — it returns nil for missing indices — so
  # VALIDATION: malformed lines produce structs with nil or misassigned fields,
  # VALIDATION: making the system appear to work when it is silently corrupt.
  def parse_line_item(line) do
    parts = String.split(line, ",")

    item_code   = Enum.at(parts, 0)
    description = Enum.at(parts, 1)
    quantity    = parts |> Enum.at(2) |> parse_integer()
    unit_price  = parts |> Enum.at(3) |> parse_decimal()
    discount    = parts |> Enum.at(4) |> parse_decimal()
    total       = parts |> Enum.at(5) |> parse_decimal()

    %{
      item_code:   item_code,
      description: description,
      quantity:    quantity,
      unit_price:  unit_price,
      discount:    discount,
      total:       total
    }
  end
  # VALIDATION: SMELL END

  def validate_line_item(%{item_code: code, quantity: qty, unit_price: price, total: total})
      when is_binary(code) and is_integer(qty) and qty > 0 and
             is_float(price) and price > 0.0 and is_float(total) do
    :ok
  end

  def validate_line_item(item) do
    {:error, "Invalid line item: #{inspect(item)}"}
  end

  def summarize(line_items) do
    total_amount =
      line_items
      |> Enum.map(& &1.total)
      |> Enum.reject(&is_nil/1)
      |> Enum.sum()

    item_count = length(line_items)

    %{
      item_count:   item_count,
      total_amount: Float.round(total_amount, 2)
    }
  end

  def group_by_item_code(line_items) do
    Enum.group_by(line_items, & &1.item_code)
  end

  def filter_discounted(line_items) do
    Enum.filter(line_items, fn item ->
      is_float(item.discount) and item.discount > 0.0
    end)
  end

  def to_csv_row(%{item_code: code, description: desc, quantity: qty,
                   unit_price: price, discount: disc, total: total}) do
    [code, desc, qty, price, disc, total]
    |> Enum.map(&to_string/1)
    |> Enum.join(",")
  end

  defp parse_integer(nil), do: nil
  defp parse_integer(str) do
    case Integer.parse(String.trim(str)) do
      {val, _} -> val
      :error   -> nil
    end
  end

  defp parse_decimal(nil), do: nil
  defp parse_decimal(str) do
    case Float.parse(String.trim(str)) do
      {val, _} -> val
      :error   -> nil
    end
  end
end
```
