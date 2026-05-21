```elixir
defmodule CsvParser do
  @moduledoc """
  A CSV parsing library for use across internal data-pipeline services.
  Supports configurable delimiters, escape characters, and optional
  header-row handling.

  Configuration (in config/config.exs):

      config :csv_parser,
        delimiter: ",",
        escape_char: "\"",
        has_header: true
  """

  require Logger

  @doc """
  Parses a CSV string into a list of maps (when `has_header: true`) or a
  list of string lists. Parsing options are read from the application
  configuration at call time.
  """
  @spec parse(String.t()) :: {:ok, list()} | {:error, String.t()}
  def parse(content) when is_binary(content) do
    delimiter = Application.fetch_env!(:csv_parser, :delimiter)
    escape_char = Application.fetch_env!(:csv_parser, :escape_char)
    has_header = Application.fetch_env!(:csv_parser, :has_header)

    lines =
      content
      |> String.split("\n", trim: true)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    case lines do
      [] ->
        {:ok, []}

      [header_line | data_lines] when has_header ->
        headers = split_row(header_line, delimiter, escape_char)

        rows =
          data_lines
          |> Enum.with_index(2)
          |> Enum.reduce_while([], fn {line, row_num}, acc ->
            values = split_row(line, delimiter, escape_char)

            if length(values) != length(headers) do
              Logger.warning("[CsvParser] Row #{row_num} has #{length(values)} fields, expected #{length(headers)}")
              {:cont, acc}
            else
              row_map = headers |> Enum.zip(values) |> Map.new()
              {:cont, [row_map | acc]}
            end
          end)

        {:ok, Enum.reverse(rows)}

      all_lines ->
        rows = Enum.map(all_lines, &split_row(&1, delimiter, escape_char))
        {:ok, rows}
    end
  end

  @doc """
  Lazily parses a CSV stream, yielding one row at a time. Useful for large
  files where loading everything into memory is not desirable.
  """
  @spec parse_stream(Enumerable.t()) :: Stream.t()
  def parse_stream(stream) do
    delimiter = Application.fetch_env!(:csv_parser, :delimiter)
    escape_char = Application.fetch_env!(:csv_parser, :escape_char)

    stream
    |> Stream.map(&String.trim/1)
    |> Stream.reject(&(&1 == ""))
    |> Stream.map(&split_row(&1, delimiter, escape_char))
  end

  @doc """
  Encodes a list of maps or lists into a CSV string.
  """
  @spec encode(list(map() | list())) :: String.t()
  def encode([]), do: ""

  def encode([first | _rest] = rows) when is_map(first) do
    headers = first |> Map.keys() |> Enum.sort()
    header_row = Enum.join(headers, ",")

    data_rows =
      Enum.map(rows, fn row ->
        headers
        |> Enum.map(&Map.get(row, &1, ""))
        |> Enum.map(&escape_field/1)
        |> Enum.join(",")
      end)

    ([header_row | data_rows] ++ [""]) |> Enum.join("\n")
  end

  def encode(rows) when is_list(rows) do
    rows
    |> Enum.map(fn row ->
      row |> Enum.map(&escape_field/1) |> Enum.join(",")
    end)
    |> Enum.join("\n")
  end

  # --- Private helpers ---

  defp split_row(line, delimiter, escape_char) do
    line
    |> String.split(delimiter)
    |> Enum.map(fn field ->
      field
      |> String.trim()
      |> String.trim(escape_char)
    end)
  end

  defp escape_field(value) do
    str = to_string(value)

    if String.contains?(str, [",", "\"", "\n"]) do
      "\"#{String.replace(str, "\"", "\\\"")}\""
    else
      str
    end
  end
end
```
