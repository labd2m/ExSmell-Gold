```elixir
defmodule Export.CSVSerializer do
  @moduledoc """
  Serializes a list of structs or maps into RFC 4180-compliant CSV output.
  Column ordering is caller-specified. Values are coerced to strings and
  special characters are escaped according to the standard. The serializer
  does not perform IO; callers receive a binary they can write, stream, or
  return over HTTP.
  """

  @type row :: map()
  @type column_spec :: {header :: String.t(), key :: term()}
  @type csv_opts :: [include_header: boolean()]

  @crlf "\r\n"

  @doc """
  Serializes `rows` into a CSV binary using the column order defined by
  `columns`, a list of `{header_label, map_key}` pairs.
  """
  @spec serialize([row()], [column_spec()], csv_opts()) :: {:ok, binary()}
  def serialize(rows, columns, opts \\ [])
      when is_list(rows) and is_list(columns) do
    include_header = Keyword.get(opts, :include_header, true)

    lines =
      if include_header do
        [build_header(columns) | build_data_lines(rows, columns)]
      else
        build_data_lines(rows, columns)
      end

    {:ok, Enum.join(lines, @crlf) <> @crlf}
  end

  @doc "Serializes a single row map into a CSV line string without trailing CRLF."
  @spec serialize_row(row(), [column_spec()]) :: String.t()
  def serialize_row(row, columns) when is_map(row) and is_list(columns) do
    columns
    |> Enum.map(fn {_header, key} -> row |> Map.get(key) |> coerce_value() |> escape_field() end)
    |> Enum.join(",")
  end

  defp build_header(columns) do
    columns
    |> Enum.map(fn {header, _key} -> escape_field(header) end)
    |> Enum.join(",")
  end

  defp build_data_lines(rows, columns) do
    Enum.map(rows, fn row -> serialize_row(row, columns) end)
  end

  defp coerce_value(nil), do: ""
  defp coerce_value(v) when is_binary(v), do: v
  defp coerce_value(v) when is_integer(v), do: Integer.to_string(v)
  defp coerce_value(v) when is_float(v), do: :erlang.float_to_binary(v, decimals: 6)
  defp coerce_value(v) when is_boolean(v), do: to_string(v)
  defp coerce_value(%Date{} = d), do: Date.to_iso8601(d)
  defp coerce_value(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp coerce_value(v), do: inspect(v)

  defp escape_field(value) when is_binary(value) do
    needs_quoting =
      String.contains?(value, [",", """, "\r", "\n"])

    if needs_quoting do
      escaped = String.replace(value, """, """")
      ""#{escaped}""
    else
      value
    end
  end
end
```
