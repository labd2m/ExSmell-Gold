# Annotated Example 11

## Metadata

- **Smell name:** Using App Configuration for libraries
- **Expected smell location:** `CSVParser.parse/1`
- **Affected function(s):** `parse/1`, `parse_line/1`
- **Short explanation:** The library fetches `:delimiter` and `:escape_char` from the application environment inside `parse/1`. Because these values are locked at a global level, callers cannot parse different CSV dialects (e.g., tab-separated vs comma-separated files) within the same application without changing global config.

## Code

```elixir
defmodule CSVParser do
  @moduledoc """
  A lightweight CSV parsing library designed to be embedded in data-pipeline
  applications. Handles quoting, escaping, and multi-line fields according to
  RFC 4180 with configurable dialect options.
  """

  @doc """
  Parses a CSV binary into a list of row lists.

  Delimiter and escape character are read from the application environment:

      config :csv_parser,
        delimiter: ",",
        escape_char: "\""

  All rows are returned as lists of binary strings. Empty input returns `[]`.
  """
  # VALIDATION: SMELL START - Using App Configuration for libraries
  # VALIDATION: This is a smell because the delimiter and escape_char are fetched
  # from Application environment at call time rather than being accepted as optional
  # keyword parameters. This prevents callers from parsing TSV and CSV files
  # simultaneously within the same application.
  def parse(data) when is_binary(data) do
    delimiter = Application.fetch_env!(:csv_parser, :delimiter)
    escape_char = Application.fetch_env!(:csv_parser, :escape_char)

    data
    |> split_lines()
    |> Enum.reject(&(&1 == ""))
    |> Enum.map(&parse_line(&1, delimiter, escape_char))
  end
  # VALIDATION: SMELL END

  @doc """
  Returns the headers (first row) from a parsed result.
  """
  def headers([first | _rest]), do: first
  def headers([]), do: []

  @doc """
  Returns all data rows (everything after the first row).
  """
  def data_rows([_header | rest]), do: rest
  def data_rows([]), do: []

  @doc """
  Converts a list of rows into a list of maps keyed by the header row values.
  """
  def to_maps(rows) when is_list(rows) and length(rows) > 1 do
    [header | data] = rows

    Enum.map(data, fn row ->
      header
      |> Enum.zip(row)
      |> Map.new()
    end)
  end

  def to_maps(_), do: []

  @doc """
  Counts the number of data rows (excluding the header).
  """
  def row_count(rows) when is_list(rows) do
    max(0, length(rows) - 1)
  end

  @doc """
  Validates that all rows have the same number of columns.
  """
  def uniform_columns?(rows) when is_list(rows) do
    rows
    |> Enum.map(&length/1)
    |> then(fn lengths ->
      case Enum.uniq(lengths) do
        [_single] -> true
        _ -> false
      end
    end)
  end

  ## Private helpers

  defp split_lines(data) do
    String.split(data, ~r/\r?\n/)
  end

  defp parse_line(line, delimiter, escape_char) do
    line
    |> tokenize(delimiter, escape_char)
    |> Enum.map(&String.trim/1)
  end

  defp tokenize(line, delimiter, escape_char) do
    line
    |> split_on_delimiter(delimiter, escape_char)
    |> Enum.map(&strip_quotes(&1, escape_char))
  end

  defp split_on_delimiter(line, delimiter, _escape_char) do
    String.split(line, delimiter)
  end

  defp strip_quotes(field, escape_char) do
    trimmed = String.trim(field)

    if String.starts_with?(trimmed, escape_char) and String.ends_with?(trimmed, escape_char) do
      trimmed
      |> String.slice(1..(String.length(trimmed) - 2))
      |> String.replace(escape_char <> escape_char, escape_char)
    else
      trimmed
    end
  end
end
```
