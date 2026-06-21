# Annotated Bad Example 15: Untested Polymorphic Behaviors

## Metadata

- **Smell name**: Untested Polymorphic Behaviors
- **Expected smell location**: `Reporting.CsvSerializer.serialize_cell/1`
- **Affected function(s)**: `serialize_cell/1`
- **Short explanation**: The function uses `Enum.join/2` on its argument, which depends on the `Enumerable` protocol. There is no guard clause ensuring the value is actually enumerable. Passing a non-enumerable type such as a plain `Integer`, `Float`, `Atom`, or binary string will raise `Protocol.UndefinedError` at runtime. The function's purpose (formatting a CSV cell that may be a list of tags) does not make sense for scalar types, and the missing guard clause leaves this completely untested and undocumented.

## Code

```elixir
defmodule Reporting.CsvSerializer do
  @moduledoc """
  Serializes report data into RFC 4180-compliant CSV format for export.
  Handles various cell types found in billing, logistics, and analytics reports.
  """

  @col_separator ","
  @row_separator "\r\n"
  @quote_char ~s(")
  @multi_value_separator "; "

  @doc """
  Converts a list of row maps into a full CSV binary, including a header row.
  The `columns` list defines both the key order and the header labels.

  ## Parameters
    - `rows`: List of maps, one per data row.
    - `columns`: List of `{key, label}` tuples defining column order and headers.
  """
  def to_csv(rows, columns) when is_list(rows) and is_list(columns) do
    headers =
      columns
      |> Enum.map(fn {_key, label} -> escape_cell(label) end)
      |> Enum.join(@col_separator)

    body =
      rows
      |> Enum.map(fn row -> serialize_row(row, columns) end)
      |> Enum.join(@row_separator)

    headers <> @row_separator <> body
  end

  @doc """
  Serializes a single map row according to the given column specification.
  """
  def serialize_row(row, columns) when is_map(row) and is_list(columns) do
    columns
    |> Enum.map(fn {key, _label} ->
      row
      |> Map.get(key, "")
      |> serialize_cell()
      |> escape_cell()
    end)
    |> Enum.join(@col_separator)
  end

  @doc """
  Serializes a single cell value to a plain string representation.

  Multi-value cells (e.g., lists of tags or category codes) are joined
  using the configured separator.
  """
  # VALIDATION: SMELL START - Untested Polymorphic Behaviors
  # VALIDATION: This is a smell because `Enum.join/2` depends on the `Enumerable`
  # protocol. The function has no guard clause — it accepts any value, including
  # non-enumerable types such as `Integer`, `Float`, `Atom`, `BitString`, or a
  # plain `Map`. Passing a scalar value will raise `Protocol.UndefinedError` at
  # runtime. Passing a `Map` would attempt to enumerate key-value pairs, producing
  # nonsensical CSV output. The function should use a guard such as `is_list(value)`
  # or provide multi-clause definitions to handle scalar vs. list values explicitly.
  def serialize_cell(value) do
    Enum.join(value, @multi_value_separator)
  end
  # VALIDATION: SMELL END

  @doc """
  Wraps a cell value in double quotes and escapes internal quote characters,
  per RFC 4180.
  """
  def escape_cell(value) when is_binary(value) do
    escaped = String.replace(value, @quote_char, @quote_char <> @quote_char)
    @quote_char <> escaped <> @quote_char
  end

  @doc """
  Returns the content-type header value appropriate for CSV downloads.
  """
  def content_type, do: "text/csv; charset=utf-8"

  @doc """
  Returns a suggested filename for a report export.
  """
  def export_filename(report_type, %Date{} = date) when is_atom(report_type) do
    "#{report_type}_#{Date.to_iso8601(date)}.csv"
  end

  @doc """
  Chunks a large row list into pages suitable for streaming exports.
  """
  def paginate(rows, page_size \\ 500)
      when is_list(rows) and is_integer(page_size) and page_size > 0 do
    Enum.chunk_every(rows, page_size)
  end

  @doc """
  Streams CSV output line by line to avoid loading the full document in memory.
  Returns a `Stream` of binary lines.
  """
  def stream_csv(rows, columns) when is_list(rows) and is_list(columns) do
    header_line =
      columns
      |> Enum.map(fn {_key, label} -> escape_cell(label) end)
      |> Enum.join(@col_separator)

    row_stream =
      Stream.map(rows, fn row ->
        serialize_row(row, columns)
      end)

    Stream.concat([header_line], row_stream)
  end
end
```
