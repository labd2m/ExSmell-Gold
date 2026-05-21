# Annotated Example 24

## Metadata

- **Smell name:** Using App Configuration for libraries
- **Expected smell location:** `CsvExporter.encode/2`
- **Affected function(s):** `encode/2`
- **Short explanation:** The library reads `:csv_delimiter` and `:csv_quote_char` from the `Application` environment inside `encode/2`. Any application depending on this library must use the same delimiter globally, making it impossible to export some reports as comma-separated and others as tab-separated (e.g., for different downstream consumers) without changing the global config at runtime.

---

```elixir
defmodule CsvExporter do
  @moduledoc """
  Library for converting tabular data structures into CSV-formatted strings.
  Used by reporting pipelines, data-export endpoints, and scheduled
  file-delivery jobs.
  """

  @type row :: [String.t() | number() | nil]
  @type table :: [row()]

  @doc """
  Encodes a list of rows into a CSV string. Each inner list represents
  one row. Values are coerced to strings, quoted if necessary, and
  joined by the configured delimiter.
  """
  @spec encode(table(), [String.t()] | nil) :: String.t()
  def encode(rows, headers \\ nil) when is_list(rows) do
    # VALIDATION: SMELL START - Using App Configuration for libraries
    # VALIDATION: This is a smell because encode/2 is a library function that
    # fetches :csv_delimiter and :csv_quote_char from the Application environment
    # instead of accepting them as optional parameters. This makes it impossible
    # for a dependent application to produce comma-delimited and tab-delimited
    # exports from different call sites without mutating global application config,
    # which is not concurrent-safe and defeats the library reuse purpose.
    delimiter = Application.fetch_env!(:csv_exporter, :csv_delimiter)
    quote_char = Application.get_env(:csv_exporter, :csv_quote_char, "\"")
    # VALIDATION: SMELL END

    all_rows =
      case headers do
        nil -> rows
        h -> [h | rows]
      end

    all_rows
    |> Enum.map(fn row -> encode_row(row, delimiter, quote_char) end)
    |> Enum.join("\n")
  end

  @doc """
  Streams a large dataset as CSV lines through a callback function,
  useful for memory-efficient generation of large exports.
  """
  @spec stream_encode(Enumerable.t(), (String.t() -> :ok)) :: :ok
  def stream_encode(data_stream, callback) when is_function(callback, 1) do
    delimiter = Application.get_env(:csv_exporter, :csv_delimiter, ",")
    quote_char = Application.get_env(:csv_exporter, :csv_quote_char, "\"")

    data_stream
    |> Stream.map(fn row -> encode_row(row, delimiter, quote_char) <> "\n" end)
    |> Enum.each(callback)
  end

  @doc """
  Converts a list of maps with uniform keys into a CSV string,
  using the map keys as the header row.
  """
  @spec from_maps([map()]) :: String.t()
  def from_maps([]) do
    ""
  end

  def from_maps([first | _] = maps) when is_map(first) do
    headers = first |> Map.keys() |> Enum.map(&to_string/1)

    rows =
      Enum.map(maps, fn row ->
        Enum.map(headers, fn h -> Map.get(row, String.to_existing_atom(h)) end)
      end)

    encode(rows, headers)
  end

  @doc "Counts the number of data rows (excluding header) in an encoded CSV string."
  @spec row_count(String.t()) :: non_neg_integer()
  def row_count(csv_string) when is_binary(csv_string) do
    csv_string
    |> String.split("\n", trim: true)
    |> length()
  end

  @doc "Returns the byte size of the encoded CSV output."
  @spec byte_size_of(String.t()) :: non_neg_integer()
  def byte_size_of(csv_string), do: byte_size(csv_string)

  # --- Private helpers ---

  defp encode_row(row, delimiter, quote_char) do
    row
    |> Enum.map(&coerce_value/1)
    |> Enum.map(fn val -> maybe_quote(val, delimiter, quote_char) end)
    |> Enum.join(delimiter)
  end

  defp coerce_value(nil), do: ""
  defp coerce_value(val) when is_float(val), do: Float.to_string(val)
  defp coerce_value(val) when is_integer(val), do: Integer.to_string(val)
  defp coerce_value(val) when is_binary(val), do: val
  defp coerce_value(val), do: inspect(val)

  defp maybe_quote(value, delimiter, quote_char) do
    needs_quoting =
      String.contains?(value, [delimiter, quote_char, "\n", "\r"])

    if needs_quoting do
      escaped = String.replace(value, quote_char, quote_char <> quote_char)
      "#{quote_char}#{escaped}#{quote_char}"
    else
      value
    end
  end
end
```
