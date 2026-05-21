# Annotated Example 36

- **Smell name:** Using exceptions for control-flow
- **Expected smell location:** `DataExporter.export_csv/2` (library) and `ExportController.download/2` (client)
- **Affected function(s):** `DataExporter.export_csv/2`, `ExportController.download/2`
- **Short explanation:** `DataExporter.export_csv/2` raises exceptions for unknown export types, column mismatches, and row count limits — common situations when exporting analytics data. Because no tuple-based alternative is provided, `ExportController.download/2` is forced to use `try...rescue` to decide what HTTP response to return for each of these expected conditions.

```elixir
defmodule DataExporter do
  @moduledoc """
  Generates CSV exports from analytics datasets.
  Supports multiple export schemas and enforces row-count safety limits.
  """

  defmodule UnknownExportTypeError do
    defexception [:message, :export_type]
  end

  defmodule RowLimitExceededError do
    defexception [:message, :row_count, :max_rows]
  end

  defmodule ColumnMismatchError do
    defexception [:message, :expected_columns, :found_columns]
  end

  defmodule EmptyDatasetError do
    defexception [:message, :export_type]
  end

  @max_rows 50_000

  @export_schemas %{
    orders: ~w(order_id customer_email status total_usd created_at),
    users: ~w(user_id email plan created_at last_login),
    refunds: ~w(refund_id charge_id amount_usd reason processed_at)
  }

  # VALIDATION: SMELL START - Using exceptions for control-flow
  # VALIDATION: This is a smell because hitting the row limit, encountering
  # an unfamiliar export type, and receiving an empty dataset are all
  # expected operating conditions for an export endpoint. Clients that need
  # to communicate these states to end users have no choice but to rely on
  # try...rescue because no tuple-returning variant exists.
  def export_csv(export_type, rows) when not is_atom(export_type) do
    raise UnknownExportTypeError,
      message: "Export type must be an atom, got: #{inspect(export_type)}",
      export_type: export_type
  end

  def export_csv(export_type, rows) do
    schema = Map.get(@export_schemas, export_type)

    if is_nil(schema) do
      raise UnknownExportTypeError,
        message:
          "Unknown export type '#{export_type}'. Known types: #{Map.keys(@export_schemas) |> Enum.join(", ")}",
        export_type: export_type
    end

    if rows == [] do
      raise EmptyDatasetError,
        message: "No data available to export for type '#{export_type}'",
        export_type: export_type
    end

    row_count = length(rows)

    if row_count > @max_rows do
      raise RowLimitExceededError,
        message:
          "Dataset has #{row_count} rows; maximum exportable is #{@max_rows}. Apply narrower filters.",
        row_count: row_count,
        max_rows: @max_rows
    end

    first_row_keys = rows |> hd() |> Map.keys() |> Enum.map(&to_string/1) |> Enum.sort()
    expected_keys = Enum.sort(schema)

    unless first_row_keys == expected_keys do
      raise ColumnMismatchError,
        message:
          "Row columns do not match the '#{export_type}' schema. " <>
            "Expected: #{inspect(expected_keys)}, found: #{inspect(first_row_keys)}",
        expected_columns: expected_keys,
        found_columns: first_row_keys
    end

    header_line = Enum.join(schema, ",")

    data_lines =
      Enum.map(rows, fn row ->
        schema
        |> Enum.map(fn col -> row[String.to_atom(col)] |> csv_escape() end)
        |> Enum.join(",")
      end)

    csv_content = Enum.join([header_line | data_lines], "\n")

    %{
      export_type: export_type,
      row_count: row_count,
      columns: schema,
      content: csv_content,
      byte_size: byte_size(csv_content),
      generated_at: DateTime.utc_now()
    }
  end
  # VALIDATION: SMELL END

  defp csv_escape(nil), do: ""
  defp csv_escape(value) when is_binary(value) do
    if String.contains?(value, [",", "\"", "\n"]) do
      "\"#{String.replace(value, "\"", "\"\"")}\""
    else
      value
    end
  end
  defp csv_escape(value), do: to_string(value)
end

defmodule ExportController do
  @moduledoc """
  Handles HTTP requests for data CSV exports.
  Streams or returns file downloads to authenticated users.
  """

  require Logger

  def download(export_type_str, query_params) do
    export_type = String.to_atom(export_type_str)
    rows = fetch_rows(export_type, query_params)

    Logger.info("Export requested: type=#{export_type}, row_count=#{length(rows)}")

    # VALIDATION: SMELL START - Using exceptions for control-flow
    # VALIDATION: This is a smell because empty datasets, row limit breaches,
    # and unfamiliar export types are all expected API usage patterns —
    # not system failures. The controller is forced to use try...rescue purely
    # because DataExporter does not offer a tuple-returning API.
    try do
      export = DataExporter.export_csv(export_type, rows)

      Logger.info(
        "CSV export ready: #{export.row_count} rows, #{export.byte_size} bytes"
      )

      {:ok,
       %{
         filename: "#{export_type}_#{Date.utc_today()}.csv",
         content_type: "text/csv",
         body: export.content
       }}
    rescue
      e in DataExporter.UnknownExportTypeError ->
        Logger.warning("Unknown export type requested: #{e.export_type}")
        {:error, :unknown_type, "Export type '#{e.export_type}' is not supported"}

      e in DataExporter.RowLimitExceededError ->
        Logger.info("Export too large: #{e.row_count} rows > #{e.max_rows} limit")
        {:error, :too_large, "Please narrow your filters; #{e.row_count} rows exceeds the #{e.max_rows} limit"}

      e in DataExporter.EmptyDatasetError ->
        Logger.debug("No data for #{e.export_type} export with current filters")
        {:ok, :empty, "No data matches the selected filters"}

      e in DataExporter.ColumnMismatchError ->
        Logger.error("Column schema mismatch for #{export_type}: #{inspect(e.found_columns)}")
        {:error, :schema_error, "Internal column mismatch; contact support"}
    end
    # VALIDATION: SMELL END
  end

  defp fetch_rows(:orders, _params) do
    [
      %{order_id: "ord-1", customer_email: "a@example.com", status: "shipped", total_usd: "49.99", created_at: "2025-09-01"}
    ]
  end

  defp fetch_rows(_type, _params), do: []
end
```
