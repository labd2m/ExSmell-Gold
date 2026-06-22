```elixir
defmodule Reporting.Exports.CsvBuilder do
  @moduledoc """
  Builds streaming CSV exports from large report datasets.

  Uses lazy Elixir streams to process arbitrarily large report result sets
  without loading the entire dataset into memory.
  """

  alias Reporting.Exports.{ColumnSchema, DataSource}

  @type export_opts :: [
          delimiter: String.t(),
          include_header: boolean(),
          encoding: :utf8 | :latin1
        ]

  @type stream_result :: Enumerable.t()

  @doc """
  Returns a lazy stream of CSV-encoded rows for the given report and column schema.

  The stream can be consumed incrementally (e.g., piped to a file or HTTP chunked response).
  Default delimiter is comma; set `delimiter: "\\t"` for TSV output.
  """
  @spec stream(DataSource.t(), [ColumnSchema.t()], export_opts()) :: stream_result()
  def stream(%DataSource{} = source, columns, opts \\ []) do
    delimiter = Keyword.get(opts, :delimiter, ",")
    include_header = Keyword.get(opts, :include_header, true)
    row_stream = DataSource.to_stream(source)

    header_stream =
      if include_header do
        [encode_header(columns, delimiter)]
      else
        []
      end

    data_stream = Stream.map(row_stream, &encode_row(&1, columns, delimiter))
    Stream.concat(header_stream, data_stream)
  end

  @doc """
  Materializes the full CSV export to a binary string.

  Suitable for small-to-medium reports. For large datasets, prefer `stream/3`
  with chunked IO instead.
  """
  @spec to_binary(DataSource.t(), [ColumnSchema.t()], export_opts()) :: binary()
  def to_binary(%DataSource{} = source, columns, opts \\ []) do
    source
    |> stream(columns, opts)
    |> Enum.join()
  end

  defp encode_header(columns, delimiter) do
    columns
    |> Enum.map(& &1.label)
    |> Enum.map(&escape_field/1)
    |> Enum.join(delimiter)
    |> append_newline()
  end

  defp encode_row(row, columns, delimiter) do
    columns
    |> Enum.map(fn col -> extract_field(row, col) end)
    |> Enum.map(&format_field/1)
    |> Enum.map(&escape_field/1)
    |> Enum.join(delimiter)
    |> append_newline()
  end

  defp extract_field(row, %ColumnSchema{key: key, formatter: nil}) do
    Map.get(row, key, "")
  end

  defp extract_field(row, %ColumnSchema{key: key, formatter: formatter}) do
    row |> Map.get(key) |> formatter.()
  end

  defp format_field(nil), do: ""
  defp format_field(value) when is_binary(value), do: value
  defp format_field(value) when is_integer(value), do: Integer.to_string(value)
  defp format_field(value) when is_float(value), do: Float.to_string(value)
  defp format_field(%Decimal{} = value), do: Decimal.to_string(value)
  defp format_field(%Date{} = value), do: Date.to_iso8601(value)
  defp format_field(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp format_field(value) when is_atom(value), do: Atom.to_string(value)

  defp escape_field(value) when is_binary(value) do
    if String.contains?(value, [",", "\"", "\n", "\r"]) do
      escaped = String.replace(value, "\"", "\"\"")
      "\"#{escaped}\""
    else
      value
    end
  end

  defp append_newline(row), do: row <> "\r\n"
end
```
