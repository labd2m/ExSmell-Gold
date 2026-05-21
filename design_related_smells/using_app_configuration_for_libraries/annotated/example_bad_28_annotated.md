# Annotated Example — Bad Code

- **Smell name:** Using App Configuration for libraries
- **Expected smell location:** `CsvParser.parse/1` and `CsvParser.parse_stream/1`
- **Affected function(s):** `parse/1`, `parse_stream/1`
- **Short explanation:** The library reads `:delimiter`, `:has_header`, and `:trim_fields` from the global `Application` environment instead of accepting them as function parameters. This forces all callers in any dependent application to share one global configuration, making it impossible to reuse the same library functions with different delimiters or options in the same app.

```elixir
defmodule CsvParser do
  @moduledoc """
  A library for parsing CSV and delimited text files into structured data.

  Supports standard CSV, TSV, and custom-delimited formats. Handles quoted
  fields, escaped characters, and optional header rows.

  Configuration is read from the application environment:

      config :csv_parser,
        delimiter: ",",
        has_header: true,
        trim_fields: true,
        max_rows: 50_000
  """

  alias CsvParser.{Row, ParseError}

  @doc """
  Parses a CSV string into a list of maps or lists depending on configuration.

  Returns `{:ok, rows}` on success or `{:error, reason}` on failure.
  """
  # VALIDATION: SMELL START - Using App Configuration for libraries
  # VALIDATION: This is a smell because the library reads delimiter, has_header,
  # and trim_fields from Application.fetch_env!/2 instead of accepting them as
  # function parameters, forcing all callers to share the same global config.
  def parse(content) when is_binary(content) do
    delimiter   = Application.fetch_env!(:csv_parser, :delimiter)
    has_header  = Application.fetch_env!(:csv_parser, :has_header)
    trim_fields = Application.fetch_env!(:csv_parser, :trim_fields)
    max_rows    = Application.fetch_env!(:csv_parser, :max_rows)
  # VALIDATION: SMELL END

    lines =
      content
      |> String.split("\n", trim: true)
      |> Enum.take(max_rows)

    case lines do
      [] ->
        {:ok, []}

      [header_line | data_lines] when has_header ->
        headers = split_line(header_line, delimiter, trim_fields)

        rows =
          data_lines
          |> Enum.with_index(2)
          |> Enum.reduce_while({:ok, []}, fn {line, line_number}, {:ok, acc} ->
            case parse_line(line, headers, delimiter, trim_fields, line_number) do
              {:ok, row}      -> {:cont, {:ok, [row | acc]}}
              {:error, _} = e -> {:halt, e}
            end
          end)

        case rows do
          {:ok, reversed} -> {:ok, Enum.reverse(reversed)}
          error           -> error
        end

      lines ->
        rows =
          lines
          |> Enum.with_index(1)
          |> Enum.reduce_while({:ok, []}, fn {line, line_number}, {:ok, acc} ->
            fields = split_line(line, delimiter, trim_fields)
            row    = Row.from_list(fields, line_number)
            {:cont, {:ok, [row | acc]}}
          end)

        case rows do
          {:ok, reversed} -> {:ok, Enum.reverse(reversed)}
          error           -> error
        end
    end
  end

  @doc """
  Parses a CSV string lazily, returning a Stream of rows.

  Useful for very large files where loading all rows at once is impractical.
  """
  def parse_stream(content) when is_binary(content) do
    delimiter   = Application.fetch_env!(:csv_parser, :delimiter)
    has_header  = Application.fetch_env!(:csv_parser, :has_header)
    trim_fields = Application.fetch_env!(:csv_parser, :trim_fields)

    lines = String.split(content, "\n", trim: true)

    case {has_header, lines} do
      {_, []} ->
        Stream.map([], & &1)

      {true, [header_line | data_lines]} ->
        headers = split_line(header_line, delimiter, trim_fields)

        data_lines
        |> Stream.with_index(2)
        |> Stream.map(fn {line, line_number} ->
          parse_line!(line, headers, delimiter, trim_fields, line_number)
        end)

      {false, all_lines} ->
        all_lines
        |> Stream.with_index(1)
        |> Stream.map(fn {line, _line_number} ->
          split_line(line, delimiter, trim_fields)
        end)
    end
  end

  @doc """
  Returns the column headers from a CSV string without parsing the full body.
  """
  def headers(content) when is_binary(content) do
    delimiter = Application.fetch_env!(:csv_parser, :delimiter)
    trim      = Application.fetch_env!(:csv_parser, :trim_fields)

    content
    |> String.split("\n", parts: 2)
    |> List.first("")
    |> split_line(delimiter, trim)
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp split_line(line, delimiter, trim) do
    fields = String.split(line, delimiter)
    if trim, do: Enum.map(fields, &String.trim/1), else: fields
  end

  defp parse_line(line, headers, delimiter, trim, line_number) do
    fields = split_line(line, delimiter, trim)

    if length(fields) != length(headers) do
      {:error,
       %ParseError{
         message: "Column count mismatch",
         line: line_number,
         expected: length(headers),
         got: length(fields)
       }}
    else
      {:ok, Enum.zip(headers, fields) |> Map.new()}
    end
  end

  defp parse_line!(line, headers, delimiter, trim, line_number) do
    case parse_line(line, headers, delimiter, trim, line_number) do
      {:ok, row}      -> row
      {:error, error} -> raise ParseError, message: error.message
    end
  end
end
```
