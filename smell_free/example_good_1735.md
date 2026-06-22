```elixir
defmodule DataExport.CsvBuilder do
  @moduledoc """
  Builds CSV export files from structured query result streams.

  Designed for large dataset exports: rows are streamed from the
  database and written to a temporary file in chunks to avoid loading
  the entire result set into memory. The caller receives a path to
  the completed file.
  """

  alias DataExport.ColumnSchema
  alias DataExport.Repo

  import Ecto.Query, warn: false

  @chunk_size 500
  @tmp_dir System.tmp_dir!()

  @type column_schema :: [ColumnSchema.t()]
  @type queryable :: Ecto.Queryable.t()

  @type build_result :: {:ok, Path.t()} | {:error, :write_failed | :query_failed}

  @doc """
  Streams rows matching the given query into a CSV file on disk.

  Returns `{:ok, file_path}` pointing to the written file, or an
  error if the query or file write fails.
  """
  @spec build(queryable(), column_schema(), String.t()) :: build_result()
  def build(queryable, columns, filename_prefix)
      when is_binary(filename_prefix) and is_list(columns) do
    path = tmp_path(filename_prefix)

    case write_csv(path, queryable, columns) do
      :ok -> {:ok, path}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec write_csv(Path.t(), queryable(), column_schema()) ::
          :ok | {:error, :write_failed | :query_failed}
  defp write_csv(path, queryable, columns) do
    header = build_header_row(columns)

    case File.open(path, [:write, :utf8]) do
      {:ok, file} ->
        IO.write(file, header)
        result = stream_rows(file, queryable, columns)
        File.close(file)
        result

      {:error, _reason} ->
        {:error, :write_failed}
    end
  end

  @spec stream_rows(IO.device(), queryable(), column_schema()) ::
          :ok | {:error, :query_failed | :write_failed}
  defp stream_rows(file, queryable, columns) do
    try do
      queryable
      |> Repo.stream(max_rows: @chunk_size)
      |> Enum.each(fn row ->
        line = build_data_row(row, columns)
        IO.write(file, line)
      end)

      :ok
    rescue
      DBConnection.ConnectionError -> {:error, :query_failed}
      File.Error -> {:error, :write_failed}
    end
  end

  @spec build_header_row(column_schema()) :: String.t()
  defp build_header_row(columns) do
    columns
    |> Enum.map(& &1.label)
    |> Enum.map(&escape_field/1)
    |> Enum.join(",")
    |> append_newline()
  end

  @spec build_data_row(map(), column_schema()) :: String.t()
  defp build_data_row(row, columns) do
    columns
    |> Enum.map(&extract_field(row, &1))
    |> Enum.map(&escape_field/1)
    |> Enum.join(",")
    |> append_newline()
  end

  @spec extract_field(map(), ColumnSchema.t()) :: String.t()
  defp extract_field(row, %ColumnSchema{key: key, formatter: nil}) do
    row |> Map.fetch!(key) |> to_string()
  end

  defp extract_field(row, %ColumnSchema{key: key, formatter: formatter})
       when is_function(formatter, 1) do
    row |> Map.fetch!(key) |> formatter.() |> to_string()
  end

  @spec escape_field(String.t()) :: String.t()
  defp escape_field(value) when is_binary(value) do
    if String.contains?(value, [",", "\"", "\n"]) do
      escaped = String.replace(value, "\"", "\"\"")
      "\"#{escaped}\""
    else
      value
    end
  end

  @spec append_newline(String.t()) :: String.t()
  defp append_newline(line), do: line <> "\n"

  @spec tmp_path(String.t()) :: Path.t()
  defp tmp_path(prefix) do
    timestamp = DateTime.utc_now() |> DateTime.to_unix(:millisecond)
    random = :crypto.strong_rand_bytes(4) |> Base.hex_encode32(case: :lower, padding: false)
    Path.join(@tmp_dir, "#{prefix}_#{timestamp}_#{random}.csv")
  end
end
```
