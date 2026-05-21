```elixir
defmodule DataImport.Schema do
  @moduledoc "Defines expected column layout and required fields for the product CSV schema."

  @columns ~w[sku name category price currency stock_quantity]
  @required ~w[sku name price]

  def columns, do: @columns
  def required, do: @required
  def column_count, do: length(@columns)
end

defmodule DataImport.ProductRecord do
  @moduledoc "A validated product record parsed from a CSV row."

  @enforce_keys [:sku, :name, :price, :currency]
  defstruct [:sku, :name, :category, :price, :currency, :stock_quantity]
end

defmodule DataImport.CsvParser do
  @moduledoc """
  Parses individual CSV rows into ProductRecord structs.
  Validates column count, required fields, and numeric types.
  """

  alias DataImport.{ProductRecord, Schema}

  def parse_row(fields, row_number) when is_list(fields) and is_integer(row_number) do
    expected = Schema.column_count()
    actual = length(fields)

    if actual != expected do
      raise RuntimeError,
        message:
          "Row #{row_number}: expected #{expected} columns but found #{actual}. " <>
            "Columns: #{Enum.join(Schema.columns(), ", ")}"
    end

    [sku, name, category, price_str, currency, qty_str] = fields

    Enum.each(Schema.required(), fn col ->
      value =
        case col do
          "sku" -> sku
          "name" -> name
          "price" -> price_str
        end

      if is_nil(value) or String.trim(value) == "" do
        raise RuntimeError,
          message: "Row #{row_number}: required column '#{col}' is empty or missing"
      end
    end)

    price =
      case Float.parse(String.trim(price_str)) do
        {val, ""} when val >= 0 ->
          val

        _ ->
          raise RuntimeError,
            message:
              "Row #{row_number}: cannot parse price '#{price_str}' as a non-negative number"
      end

    stock_quantity =
      case Integer.parse(String.trim(qty_str || "0")) do
        {val, ""} -> val
        _ -> 0
      end

    %ProductRecord{
      sku: String.trim(sku),
      name: String.trim(name),
      category: if(String.trim(category || "") == "", do: nil, else: String.trim(category)),
      price: price,
      currency: String.upcase(String.trim(currency)),
      stock_quantity: stock_quantity
    }
  end
end

defmodule DataImport.ProductImporter do
  @moduledoc """
  Reads a CSV payload (already split into rows) and attempts to parse each row
  into a ProductRecord. Collects parse errors per-row rather than aborting.
  """

  alias DataImport.CsvParser
  require Logger

  def import(rows, opts \\ []) when is_list(rows) do
    skip_header = Keyword.get(opts, :skip_header, true)
    data_rows = if skip_header, do: tl(rows), else: rows

    Logger.info("Starting import of #{length(data_rows)} data rows")

    {records, errors} =
      data_rows
      |> Enum.with_index(if(skip_header, do: 2, else: 1))
      |> Enum.reduce({[], []}, fn {row, row_num}, {rec_acc, err_acc} ->
        fields = String.split(row, ",")

        # Client forced to use try/rescue because CsvParser.parse_row/2 raises
        # on all parsing failures instead of returning {:error, reason}.
        try do
          record = CsvParser.parse_row(fields, row_num)
          {[record | rec_acc], err_acc}
        rescue
          e in RuntimeError ->
            Logger.warning("Import parse error: #{e.message}")
            {rec_acc, [{row_num, e.message} | err_acc]}
        end
      end)

    Logger.info("Import complete: #{length(records)} ok, #{length(errors)} errors")

    %{
      imported: Enum.reverse(records),
      errors: Enum.reverse(errors),
      total: length(data_rows),
      success_count: length(records),
      error_count: length(errors)
    }
  end

  def import_from_string(csv_string, opts \\ []) do
    rows = String.split(csv_string, "\n", trim: true)
    import(rows, opts)
  end
end
```
