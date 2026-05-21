# Annotated Example — Untested Polymorphic Behaviors

## Metadata

- **Smell name:** Untested polymorphic behaviors
- **Expected smell location:** `Reporting.CsvExporter.render_cell/1`
- **Affected function(s):** `render_cell/1`
- **Short explanation:** `render_cell/1` calls `to_string/1` on any value passed from a report
  row without guard clauses. The function is intended to handle scalars (strings, numbers,
  atoms, dates formatted as strings). However, `Date` and `DateTime` structs implement
  `String.Chars` and silently produce their internal `inspect` representation instead of an
  ISO-8601 string, corrupting date columns in the exported file. Passing a `Map` or `List`
  (e.g., a nested aggregation) raises `Protocol.UndefinedError`, crashing the streaming
  exporter mid-file and producing a truncated, invalid CSV.

---

```elixir
defmodule Reporting.CsvExporter do
  @moduledoc """
  Streams report data as RFC 4180-compliant CSV to an IO device or
  collects it into a binary. Used by the scheduled reporting pipeline
  and the on-demand export endpoint.

  Each report is described by a schema that lists column names and the
  corresponding accessor functions applied to each data row.
  """

  @doc """
  Exports `rows` using `schema` and writes the result to `io_device`.

  ## Schema format

      [
        %{header: "Order ID",   accessor: & &1.order_id},
        %{header: "Total",      accessor: & &1.total},
        %{header: "Created At", accessor: & &1.inserted_at}
      ]
  """
  def stream_to_device(rows, schema, io_device) do
    header_line = render_header(schema)
    IO.write(io_device, header_line <> "\n")

    Enum.each(rows, fn row ->
      line = render_row(row, schema)
      IO.write(io_device, line <> "\n")
    end)

    :ok
  end

  @doc """
  Collects all rows into a single CSV binary string.
  Suitable for small to medium datasets (< 50 MB).
  """
  def to_binary(rows, schema) do
    header = render_header(schema)

    data_lines =
      rows
      |> Enum.map(&render_row(&1, schema))
      |> Enum.join("\n")

    {:ok, header <> "\n" <> data_lines}
  rescue
    e -> {:error, Exception.message(e)}
  end

  @doc "Writes a CSV export directly to a temporary file and returns its path."
  def to_temp_file(rows, schema) do
    path = System.tmp_dir!() |> Path.join("report_#{System.unique_integer([:positive])}.csv")

    with {:ok, device} <- File.open(path, [:write, :utf8]),
         :ok <- stream_to_device(rows, schema, device),
         :ok <- File.close(device) do
      {:ok, path}
    end
  end

  # ---------------------------------------------------------------------------
  # Row and cell rendering
  # ---------------------------------------------------------------------------

  @doc "Renders the header row from the schema column definitions."
  def render_header(schema) do
    schema
    |> Enum.map(fn col -> quote_cell(col.header) end)
    |> Enum.join(",")
  end

  @doc "Renders a single data row by applying each column's accessor."
  def render_row(row, schema) do
    schema
    |> Enum.map(fn col ->
      col.accessor.(row) |> render_cell()
    end)
    |> Enum.join(",")
  end

  # VALIDATION: SMELL START - Untested polymorphic behaviors
  # VALIDATION: This is a smell because render_cell/1 calls to_string/1 on any
  # VALIDATION: value extracted by a schema accessor without a guard or pattern
  # VALIDATION: match. The function is supposed to convert scalar report values
  # VALIDATION: (strings, numbers, atoms) into CSV-safe strings. In practice:
  # VALIDATION: - A NaiveDateTime struct implements String.Chars (via Calendar)
  # VALIDATION:   and produces a human-readable string, but its format differs
  # VALIDATION:   from ISO-8601, silently corrupting date columns.
  # VALIDATION: - A Decimal struct (used for monetary amounts in many apps)
  # VALIDATION:   also implements String.Chars, so it "works", but the caller
  # VALIDATION:   has no contract guarantee—a future change to return a float
  # VALIDATION:   tuple would silently break.
  # VALIDATION: - A Map or List (e.g., a nested tag list or metadata map)
  # VALIDATION:   raises Protocol.UndefinedError, crashing stream_to_device/3
  # VALIDATION:   mid-write and leaving the output file truncated.
  @doc """
  Converts a single cell value to a quoted CSV string.
  Escapes internal double-quote characters per RFC 4180.
  """
  def render_cell(value) do
    str = to_string(value)
    quote_cell(str)
  end
  # VALIDATION: SMELL END

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp quote_cell(str) when is_binary(str) do
    escaped = String.replace(str, "\"", "\"\"")
    "\"#{escaped}\""
  end

  defp build_schema_from_keys(keys) when is_list(keys) do
    Enum.map(keys, fn key ->
      %{
        header: key |> to_string() |> String.replace("_", " ") |> String.capitalize(),
        accessor: fn row -> Map.get(row, key) end
      }
    end)
  end

  defp count_columns(schema), do: length(schema)

  defp validate_schema(schema) when is_list(schema) and length(schema) > 0, do: :ok
  defp validate_schema(_), do: {:error, :empty_schema}
end
```
