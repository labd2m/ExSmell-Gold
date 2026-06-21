# File: `example_good_09.md`

```elixir
defmodule Reports.CsvExporter do
  @moduledoc """
  Builds CSV exports from structured report data.

  Accepts a schema describing column names and field extractors, then
  streams records through encoding. Large datasets are written to a
  temporary file to avoid holding the full output in memory.
  """

  @type column :: %{
          required(:header) => String.t(),
          required(:field) => atom() | (map() -> String.t())
        }

  @type export_opts :: [
          delimiter: String.t(),
          line_ending: String.t(),
          include_bom: boolean()
        ]

  @type export_result ::
          {:ok, String.t()}
          | {:error, :no_columns}
          | {:error, :write_failed}

  @utf8_bom <<0xEF, 0xBB, 0xBF>>

  @doc """
  Exports `records` to a CSV file at `destination_path` using the
  provided column schema.

  Options:
  - `:delimiter` — field delimiter character (default: `","`)
  - `:line_ending` — row terminator (default: `"\\r\\n"`)
  - `:include_bom` — prepend UTF-8 BOM for Excel compatibility (default: `false`)

  Returns `{:ok, destination_path}` on success.
  """
  @spec export([map()], [column()], String.t(), export_opts()) :: export_result()
  def export(records, columns, destination_path, opts \\ [])
      when is_list(records) and is_list(columns) and is_binary(destination_path) do
    with :ok <- validate_columns(columns),
         {:ok, file} <- open_file(destination_path),
         :ok <- write_all(file, records, columns, opts) do
      File.close(file)
      {:ok, destination_path}
    else
      {:error, :no_columns} = err -> err
      {:error, _posix} -> {:error, :write_failed}
    end
  end

  @doc """
  Encodes a single record as a CSV row string according to the column schema.

  Useful for streaming or testing individual row output without file I/O.
  """
  @spec encode_row(map(), [column()], String.t()) :: String.t()
  def encode_row(record, columns, delimiter \\ ",") when is_map(record) and is_list(columns) do
    columns
    |> Enum.map(&extract_cell(record, &1))
    |> Enum.map(&escape_cell(&1, delimiter))
    |> Enum.join(delimiter)
  end

  defp validate_columns([]), do: {:error, :no_columns}
  defp validate_columns(columns) when is_list(columns), do: :ok

  defp open_file(path) do
    case File.open(path, [:write, :utf8]) do
      {:ok, _file} = ok -> ok
      {:error, _reason} = err -> err
    end
  end

  defp write_all(file, records, columns, opts) do
    delimiter = Keyword.get(opts, :delimiter, ",")
    line_ending = Keyword.get(opts, :line_ending, "\r\n")
    include_bom = Keyword.get(opts, :include_bom, false)

    with :ok <- maybe_write_bom(file, include_bom),
         :ok <- write_header(file, columns, delimiter, line_ending),
         :ok <- write_rows(file, records, columns, delimiter, line_ending) do
      :ok
    end
  end

  defp maybe_write_bom(_file, false), do: :ok

  defp maybe_write_bom(file, true) do
    IO.binwrite(file, @utf8_bom)
  end

  defp write_header(file, columns, delimiter, line_ending) do
    header =
      columns
      |> Enum.map(& &1.header)
      |> Enum.map(&escape_cell(&1, delimiter))
      |> Enum.join(delimiter)

    IO.write(file, header <> line_ending)
  end

  defp write_rows(file, records, columns, delimiter, line_ending) do
    Enum.reduce_while(records, :ok, fn record, _acc ->
      row = encode_row(record, columns, delimiter)

      case IO.write(file, row <> line_ending) do
        :ok -> {:cont, :ok}
        {:error, _reason} -> {:halt, {:error, :write_failed}}
      end
    end)
  end

  defp extract_cell(record, %{field: field}) when is_atom(field) do
    record
    |> Map.get(field, "")
    |> to_string()
  end

  defp extract_cell(record, %{field: extractor}) when is_function(extractor, 1) do
    record
    |> extractor.()
    |> to_string()
  end

  defp escape_cell(value, delimiter) do
    needs_quoting =
      String.contains?(value, [delimiter, "\"", "\n", "\r"])

    if needs_quoting do
      escaped = String.replace(value, "\"", "\"\"")
      "\"#{escaped}\""
    else
      value
    end
  end
end
```
