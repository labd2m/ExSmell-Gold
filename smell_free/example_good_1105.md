```elixir
defmodule Ingestion.CSVParser do
  @moduledoc """
  Parses CSV streams into typed row structs.
  Handles header normalization, type coercion per column schema,
  and collects per-row errors without aborting the entire stream.
  """

  @type column_type :: :string | :integer | :float | :boolean | :date
  @type column_schema :: %{required(String.t()) => column_type()}
  @type parsed_row :: %{required(String.t()) => term()}
  @type row_result :: {:ok, parsed_row()} | {:error, {pos_integer(), [String.t()]}}

  @doc """
  Parses an enumerable of raw CSV lines using the supplied column schema.
  Returns a list of per-row results preserving row index for error attribution.
  """
  @spec parse(Enumerable.t(), column_schema()) :: [row_result()]
  def parse(lines, schema) when is_map(schema) do
    lines
    |> Stream.map(&String.trim/1)
    |> Stream.reject(&(&1 == ""))
    |> parse_with_header(schema)
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp parse_with_header(stream, schema) do
    [header_line | data_lines] = Enum.to_list(stream)
    headers = split_row(header_line)

    data_lines
    |> Enum.with_index(2)
    |> Enum.map(fn {line, row_index} ->
      values = split_row(line)
      coerce_row(headers, values, schema, row_index)
    end)
  end

  defp split_row(line), do: String.split(line, ",", trim: false)

  defp coerce_row(headers, values, schema, row_index) do
    headers
    |> Enum.zip(values)
    |> Enum.reduce({:ok, %{}, []}, fn {header, raw}, {status, acc, errors} ->
      col_type = Map.get(schema, header, :string)
      case coerce_value(raw, col_type) do
        {:ok, value} -> {status, Map.put(acc, header, value), errors}
        {:error, msg} -> {:error, acc, [msg | errors]}
      end
    end)
    |> finalize_row(row_index)
  end

  defp finalize_row({:ok, row, []}, _index), do: {:ok, row}
  defp finalize_row({:error, _partial, errors}, index), do: {:error, {index, Enum.reverse(errors)}}

  defp coerce_value(raw, :string), do: {:ok, String.trim(raw)}
  defp coerce_value(raw, :integer) do
    case Integer.parse(String.trim(raw)) do
      {int, ""} -> {:ok, int}
      _ -> {:error, "expected integer, got: #{raw}"}
    end
  end
  defp coerce_value(raw, :float) do
    case Float.parse(String.trim(raw)) do
      {float, ""} -> {:ok, float}
      _ -> {:error, "expected float, got: #{raw}"}
    end
  end
  defp coerce_value("true", :boolean), do: {:ok, true}
  defp coerce_value("false", :boolean), do: {:ok, false}
  defp coerce_value(raw, :boolean), do: {:error, "expected boolean, got: #{raw}"}
  defp coerce_value(raw, :date) do
    case Date.from_iso8601(String.trim(raw)) do
      {:ok, date} -> {:ok, date}
      {:error, _} -> {:error, "expected ISO date, got: #{raw}"}
    end
  end
end
```
