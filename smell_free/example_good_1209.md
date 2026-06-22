```elixir
defmodule MyApp.Reporting.CsvRenderer do
  @moduledoc """
  Renders a list of maps into RFC 4180–compliant CSV output. Column
  ordering is controlled by an explicit header list rather than Map
  key ordering to ensure stability across Elixir versions. Values are
  escaped according to the RFC: fields containing commas, double-quotes,
  or newlines are wrapped in double-quotes with internal quotes doubled.
  """

  @type header :: String.t()
  @type row :: map()

  @doc """
  Renders `rows` as a CSV string with the given `headers` defining
  column order. Missing fields default to an empty string.
  """
  @spec render([header()], [row()]) :: String.t()
  def render(headers, rows) when is_list(headers) and is_list(rows) do
    [encode_row(headers) | Enum.map(rows, &encode_row(extract_values(&1, headers)))]
    |> Enum.join("\r\n")
    |> then(&(&1 <> "\r\n"))
  end

  @doc """
  Streams `rows` as CSV lines to `device`, writing the header first.
  Returns `{:ok, count}` of data rows written.
  """
  @spec stream_to(IO.device(), [header()], Enumerable.t()) :: {:ok, non_neg_integer()}
  def stream_to(device, headers, rows) when is_list(headers) do
    IO.write(device, encode_row(headers) <> "\r\n")

    count =
      Enum.reduce(rows, 0, fn row, acc ->
        line = row |> extract_values(headers) |> encode_row()
        IO.write(device, line <> "\r\n")
        acc + 1
      end)

    {:ok, count}
  end

  @doc "Encodes a single list of string values as a CSV row string."
  @spec encode_row([String.t()]) :: String.t()
  def encode_row(values) when is_list(values) do
    values
    |> Enum.map(&escape_field/1)
    |> Enum.join(",")
  end

  @doc "Escapes a single field value per RFC 4180."
  @spec escape_field(term()) :: String.t()
  def escape_field(nil), do: ""

  def escape_field(value) do
    str = to_string(value)

    if String.contains?(str, [",", "\"", "\n", "\r"]) do
      "\"#{String.replace(str, "\"", "\"\"")}\""
    else
      str
    end
  end

  @spec extract_values(row(), [header()]) :: [String.t()]
  defp extract_values(row, headers) do
    Enum.map(headers, fn header ->
      Map.get(row, header) || Map.get(row, String.to_atom(header))
    end)
  end
end
```
