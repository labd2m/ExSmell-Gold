```elixir
defmodule Reporting.CsvExporter do
  @moduledoc """
  Streams large Ecto query results directly to a CSV without loading the
  entire dataset into memory.

  The exporter uses `Repo.stream/2` inside a transaction to lazily pull
  rows, encodes each batch to CSV, and writes to any `IO.device` target —
  a file, an HTTP response stream, or an in-memory buffer.
  """

  alias NimbleCSV.RFC4180, as: CSV
  alias Platform.Repo

  @type column_spec :: [{header :: String.t(), field_fn :: (struct() -> term())}]
  @type export_result :: {:ok, non_neg_integer()} | {:error, term()}

  @default_chunk_size 500

  @doc """
  Exports the result of `queryable` to `io_device` as CSV.

  `columns` is a list of `{header_string, value_fn}` pairs that map each row
  to its CSV cells. Returns `{:ok, row_count}` on completion.
  """
  @spec export(Ecto.Queryable.t(), column_spec(), IO.device(), keyword()) :: export_result()
  def export(queryable, columns, io_device, opts \\ []) do
    chunk_size = Keyword.get(opts, :chunk_size, @default_chunk_size)

    result =
      Repo.transaction(fn ->
        write_headers(columns, io_device)

        queryable
        |> Repo.stream(max_rows: chunk_size)
        |> Stream.map(&row_to_cells(&1, columns))
        |> Stream.chunk_every(chunk_size)
        |> Stream.each(&write_chunk(&1, io_device))
        |> Enum.reduce(0, fn chunk, count -> count + length(chunk) end)
      end, timeout: :infinity)

    case result do
      {:ok, count} -> {:ok, count}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Exports to a binary string instead of an IO device.
  Suitable for small result sets or in-memory payloads.
  """
  @spec export_to_string(Ecto.Queryable.t(), column_spec(), keyword()) ::
          {:ok, String.t()} | {:error, term()}
  def export_to_string(queryable, columns, opts \\ []) do
    {:ok, device} = StringIO.open("")

    with {:ok, _count} <- export(queryable, columns, device, opts) do
      {:ok, contents} = StringIO.close(device)
      {:ok, contents}
    end
  end

  defp write_headers(columns, device) do
    headers = Enum.map(columns, fn {header, _fn} -> header end)
    encoded = CSV.dump_to_iodata([headers])
    IO.write(device, encoded)
  end

  defp row_to_cells(row, columns) do
    Enum.map(columns, fn {_header, value_fn} ->
      row |> value_fn.() |> to_csv_value()
    end)
  end

  defp write_chunk(rows, device) do
    encoded = CSV.dump_to_iodata(rows)
    IO.write(device, encoded)
  end

  defp to_csv_value(nil), do: ""
  defp to_csv_value(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp to_csv_value(%Date{} = d), do: Date.to_iso8601(d)
  defp to_csv_value(value) when is_atom(value), do: Atom.to_string(value)
  defp to_csv_value(value) when is_float(value), do: Float.to_string(value)
  defp to_csv_value(value) when is_integer(value), do: Integer.to_string(value)
  defp to_csv_value(value) when is_binary(value), do: value
  defp to_csv_value(value), do: inspect(value)
end
```
