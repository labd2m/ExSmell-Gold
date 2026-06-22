```elixir
defmodule ExportPipeline.Format do
  @moduledoc """
  Enumerates supported export formats and provides content-type metadata.
  """

  @type t :: :csv | :json | :ndjson

  @spec content_type(t()) :: String.t()
  def content_type(:csv), do: "text/csv"
  def content_type(:json), do: "application/json"
  def content_type(:ndjson), do: "application/x-ndjson"

  @spec file_extension(t()) :: String.t()
  def file_extension(:csv), do: ".csv"
  def file_extension(:json), do: ".json"
  def file_extension(:ndjson), do: ".ndjson"

  @spec all() :: list(t())
  def all, do: [:csv, :json, :ndjson]
end

defmodule ExportPipeline.Serializer do
  @moduledoc """
  Converts a stream of row maps into the target format bytes.
  Each format is handled by a focused private function to keep
  encoding logic isolated and independently testable.
  """

  alias ExportPipeline.Format

  @spec serialize(Enumerable.t(), Format.t()) :: {:ok, binary()} | {:error, atom()}
  def serialize(rows, :csv), do: serialize_csv(rows)
  def serialize(rows, :json), do: serialize_json(rows)
  def serialize(rows, :ndjson), do: serialize_ndjson(rows)

  defp serialize_csv(rows) do
    rows_list = Enum.to_list(rows)

    with [first | _] <- rows_list,
         headers <- first |> Map.keys() |> Enum.map(&to_string/1) do
      header_line = Enum.join(headers, ",")

      data_lines =
        Enum.map(rows_list, fn row ->
          headers |> Enum.map(&Map.get(row, String.to_existing_atom(&1), "")) |> Enum.map(&csv_cell/1) |> Enum.join(",")
        end)

      {:ok, Enum.join([header_line | data_lines], "\n")}
    else
      [] -> {:ok, ""}
    end
  rescue
    _ -> {:error, :csv_serialization_failed}
  end

  defp serialize_json(rows) do
    case Jason.encode(Enum.to_list(rows)) do
      {:ok, _} = result -> result
      {:error, _} -> {:error, :json_serialization_failed}
    end
  end

  defp serialize_ndjson(rows) do
    result =
      rows
      |> Enum.map(&Jason.encode!/1)
      |> Enum.join("\n")

    {:ok, result}
  rescue
    _ -> {:error, :ndjson_serialization_failed}
  end

  defp csv_cell(nil), do: ""
  defp csv_cell(value) when is_binary(value), do: ~s("#{String.replace(value, ~s("), ~s(""))}")
  defp csv_cell(value), do: to_string(value)
end

defmodule ExportPipeline.Job do
  @moduledoc """
  Coordinates a full data export: fetches rows from a query function,
  serializes them to the requested format, and writes the result to disk.
  Returns a structured outcome including the output path and row count.
  """

  alias ExportPipeline.{Format, Serializer}

  @type row :: map()
  @type fetch_fn :: (-> Enumerable.t())

  @type result :: %{
          path: String.t(),
          format: Format.t(),
          row_count: non_neg_integer(),
          size_bytes: non_neg_integer()
        }

  @spec run(fetch_fn(), Format.t(), String.t()) :: {:ok, result()} | {:error, atom()}
  def run(fetch_fn, format, output_dir)
      when is_function(fetch_fn, 0) and is_binary(output_dir) do
    rows = fetch_fn.()
    rows_list = Enum.to_list(rows)

    with {:ok, content} <- Serializer.serialize(rows_list, format),
         {:ok, path} <- write_output(content, format, output_dir) do
      {:ok,
       %{
         path: path,
         format: format,
         row_count: length(rows_list),
         size_bytes: byte_size(content)
       }}
    end
  end

  defp write_output(content, format, dir) do
    filename = "export_#{timestamp()}#{Format.file_extension(format)}"
    path = Path.join(dir, filename)

    case File.write(path, content) do
      :ok -> {:ok, path}
      {:error, reason} -> {:error, {:write_failed, reason}}
    end
  end

  defp timestamp do
    DateTime.utc_now() |> DateTime.to_iso8601(:basic) |> String.replace(~r/[:\-]/, "")
  end
end
```
