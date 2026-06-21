```elixir
defmodule Export.CsvFormatter do
  @moduledoc """
  Formats a stream of row maps into RFC 4180-compliant CSV chunks.

  The formatter accepts a list of column specs declaring field name and
  header label. Each row map is projected in column-spec order; missing
  fields emit an empty cell rather than raising.
  """

  @type column_spec :: %{required(:field) => atom(), required(:label) => String.t()}

  @spec header_row([column_spec()]) :: iodata()
  def header_row(columns) when is_list(columns) do
    columns
    |> Enum.map(& &1.label)
    |> encode_row()
  end

  @spec format_row(map(), [column_spec()]) :: iodata()
  def format_row(row, columns) when is_map(row) and is_list(columns) do
    columns
    |> Enum.map(fn col -> row |> Map.get(col.field) |> cell_value() end)
    |> encode_row()
  end

  defp encode_row(cells) do
    cells
    |> Enum.map_join(",", &escape_cell/1)
    |> Kernel.<>("\r\n")
  end

  defp escape_cell(cell) do
    if String.contains?(cell, [",", "\"", "\r", "\n"]) do
      "\"#{String.replace(cell, "\"", "\"\"")}\" "
    else
      cell
    end
  end

  defp cell_value(nil), do: ""
  defp cell_value(value) when is_binary(value), do: value
  defp cell_value(value) when is_integer(value), do: Integer.to_string(value)
  defp cell_value(value) when is_float(value), do: Float.to_string(value)
  defp cell_value(%Date{} = d), do: Date.to_string(d)
  defp cell_value(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp cell_value(value), do: inspect(value)
end

defmodule Export.StreamExporter do
  @moduledoc """
  Exports a lazy stream of domain records to a destination IO device
  as a streamed CSV, row-by-row, without loading the entire dataset
  into memory.

  The caller supplies a `Stream` or `Enumerable` of row maps, a list
  of column specs, and an `IO.device` to write into. Progress is
  reported via optional telemetry events so callers can drive progress
  indicators.
  """

  alias Export.CsvFormatter

  @type column_spec :: CsvFormatter.column_spec()

  @type export_opts :: [
          telemetry_prefix: [atom()],
          batch_size: pos_integer()
        ]

  @spec export(Enumerable.t(), [column_spec()], IO.device(), export_opts()) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def export(rows, columns, device, opts \\ []) do
    prefix = Keyword.get(opts, :telemetry_prefix, [:export, :csv])

    header = CsvFormatter.header_row(columns)
    IO.write(device, header)

    {count, error} =
      Enum.reduce_while(rows, {0, nil}, fn row, {count, _} ->
        try do
          chunk = CsvFormatter.format_row(row, columns)
          IO.write(device, chunk)
          emit_progress(prefix, count + 1)
          {:cont, {count + 1, nil}}
        rescue
          error -> {:halt, {count, error}}
        end
      end)

    case error do
      nil -> {:ok, count}
      err -> {:error, err}
    end
  end

  @spec to_stream([column_spec()]) :: (Enumerable.t() -> Enumerable.t())
  def to_stream(columns) do
    fn rows ->
      header_stream = Stream.once(fn -> CsvFormatter.header_row(columns) end)
      row_stream = Stream.map(rows, &CsvFormatter.format_row(&1, columns))
      Stream.concat(header_stream, row_stream)
    end
  end

  defp emit_progress(prefix, count) when rem(count, 1_000) == 0 do
    :telemetry.execute(prefix ++ [:progress], %{rows_written: count}, %{})
  end

  defp emit_progress(_prefix, _count), do: :ok
end
```
