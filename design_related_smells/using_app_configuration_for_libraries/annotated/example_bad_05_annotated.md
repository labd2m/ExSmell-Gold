# Annotated Example 05

- **Smell name:** Using App Configuration for libraries
- **Expected smell location:** `CsvExporter.export/1`
- **Affected functions:** `export/1`
- **Short explanation:** The library reads `:delimiter`, `:line_ending`, and `:include_header` from the Application Environment. This prevents callers from generating differently-formatted CSV outputs in the same application (e.g., comma-delimited for one partner, semicolon-delimited for another) without modifying global config.

```elixir
defmodule CsvExporter do
  @moduledoc """
  A CSV generation library for exporting tabular data.
  Used by reporting, data pipeline, and partner integration modules.
  Supports custom delimiters, line endings, and header control.
  """

  @doc """
  Exports a list of row maps to a CSV binary string.

  The first row's keys are used as column headers, unless headers
  are disabled via configuration. Row order is preserved.

  ## Example

      rows = [
        %{name: "Alice", age: 30, city: "NYC"},
        %{name: "Bob",   age: 25, city: "LA"}
      ]
      {:ok, csv} = CsvExporter.export(rows)

  """
  # VALIDATION: SMELL START - Using App Configuration for libraries
  # VALIDATION: This is a smell because delimiter, line_ending, and include_header
  # are read from the Application Environment instead of being accepted as
  # optional parameters. A reporting module that generates comma-delimited CSVs
  # for internal use and semicolon-delimited CSVs for European partners cannot
  # use this library for both without swapping global config between calls.
  def export(rows) when is_list(rows) do
    delimiter   = Application.fetch_env!(:csv_exporter, :delimiter)
    line_ending = Application.fetch_env!(:csv_exporter, :line_ending)
    include_hdr = Application.fetch_env!(:csv_exporter, :include_header)

    if rows == [] do
      {:ok, ""}
    else
      columns = rows |> List.first() |> Map.keys()

      header_line =
        if include_hdr do
          columns
          |> Enum.map(&to_string/1)
          |> Enum.map(&escape_field(&1, delimiter))
          |> Enum.join(delimiter)
        else
          nil
        end

      data_lines =
        Enum.map(rows, fn row ->
          columns
          |> Enum.map(&Map.get(row, &1, ""))
          |> Enum.map(&to_string/1)
          |> Enum.map(&escape_field(&1, delimiter))
          |> Enum.join(delimiter)
        end)

      all_lines =
        if header_line, do: [header_line | data_lines], else: data_lines

      {:ok, Enum.join(all_lines, line_ending) <> line_ending}
    end
  end
  # VALIDATION: SMELL END

  @doc """
  Exports rows and writes the result directly to a file path.
  Returns {:ok, path} or {:error, reason}.
  """
  def export_to_file(rows, path) when is_list(rows) and is_binary(path) do
    with {:ok, csv} <- export(rows),
         :ok <- File.write(path, csv) do
      {:ok, path}
    end
  end

  @doc """
  Streams rows from an Enumerable and builds a CSV binary.
  Useful when rows come from a database cursor or a lazy stream.
  """
  def stream_export(enumerable) do
    rows = Enum.to_list(enumerable)
    export(rows)
  end

  @doc """
  Validates that all rows share the same schema (same keys).
  Returns :ok or {:error, :schema_mismatch}.
  """
  def validate_schema(rows) when is_list(rows) and length(rows) > 1 do
    [first | rest] = rows
    expected_keys = Map.keys(first) |> Enum.sort()

    mismatch =
      Enum.find(rest, fn row ->
        Map.keys(row) |> Enum.sort() != expected_keys
      end)

    if mismatch, do: {:error, :schema_mismatch}, else: :ok
  end

  def validate_schema(_), do: :ok

  # --- Private helpers ---

  defp escape_field(value, delimiter) do
    needs_quoting =
      String.contains?(value, [delimiter, "\"", "\n", "\r"])

    if needs_quoting do
      escaped = String.replace(value, "\"", "\"\"")
      "\"#{escaped}\""
    else
      value
    end
  end
end
```
