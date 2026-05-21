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
 
  def serialize_cell(value) do
    Enum.join(value, @multi_value_separator)
  end

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
