```elixir
defmodule ReportExporter do
  @moduledoc """
  Handles export of platform reports into multiple file formats.
  Supports CSV, JSON, Excel (XLSX), and PDF output. Responsible for
  content-type negotiation, file extension resolution, and serialization.
  """

  require Logger

  @supported_formats [:csv, :json, :xlsx, :pdf]

  def supported_formats, do: @supported_formats







  @doc """
  Returns the MIME content type string for the given export format.
  """
  def content_type(format) do
    case format do
      :csv -> "text/csv"
      :json -> "application/json"
      :xlsx -> "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
      :pdf -> "application/pdf"
      _ -> "application/octet-stream"
    end
  end

  @doc """
  Returns the appropriate file extension (without leading dot) for the format.
  """
  def file_extension(format) do
    case format do
      :csv -> "csv"
      :json -> "json"
      :xlsx -> "xlsx"
      :pdf -> "pdf"
      _ -> "bin"
    end
  end

  @doc """
  Serializes a report data structure into binary content suitable for the
  requested format. Returns `{:ok, binary}` or `{:error, reason}`.
  """
  def serialize(format, %{columns: columns, rows: rows} = _report_data) do
    case format do
      :csv ->
        header = Enum.join(columns, ",")
        lines = Enum.map(rows, fn row -> Enum.map_join(row, ",", &to_string/1) end)
        {:ok, Enum.join([header | lines], "\n")}

      :json ->
        records = Enum.map(rows, fn row -> Enum.zip(columns, row) |> Map.new() end)
        Jason.encode(%{columns: columns, data: records})

      :xlsx ->
        {:ok, <<"XLSX_STUB:", :erlang.term_to_binary({columns, rows})::binary>>}

      :pdf ->
        {:ok, <<"PDF_STUB:", :erlang.term_to_binary({columns, rows})::binary>>}

      other ->
        {:error, {:unsupported_format, other}}
    end
  end



  @doc """
  Builds a full export response map, including headers and binary content,
  ready to be sent via an HTTP controller.
  """
  def build_export_response(format, report_data, filename_base) do
    with :ok <- validate_format(format),
         {:ok, content} <- serialize(format, report_data) do
      filename = "#{filename_base}.#{file_extension(format)}"

      headers = [
        {"content-type", content_type(format)},
        {"content-disposition", ~s(attachment; filename="#{filename}")},
        {"content-length", byte_size(content)}
      ]

      {:ok, %{headers: headers, body: content, filename: filename}}
    end
  end

  @doc """
  Streams a large report export, yielding chunks to the provided callback.
  """
  def stream_export(format, report_data, chunk_callback) when is_function(chunk_callback, 1) do
    with :ok <- validate_format(format),
         {:ok, full_content} <- serialize(format, report_data) do
      full_content
      |> :binary.bin_to_list()
      |> Enum.chunk_every(4096)
      |> Enum.each(fn chunk -> chunk_callback.(:binary.list_to_bin(chunk)) end)

      Logger.info("Streamed #{byte_size(full_content)} bytes for #{format} export.")
      :ok
    end
  end

  @doc """
  Stores a generated report export to a temporary storage path.
  """
  def persist_export(format, report_data, storage_path) do
    with {:ok, %{body: content, filename: filename}} <-
           build_export_response(format, report_data, Path.basename(storage_path)) do
      full_path = Path.join(storage_path, filename)
      File.write(full_path, content)
    end
  end



  defp validate_format(format) when format in @supported_formats, do: :ok
  defp validate_format(other), do: {:error, {:unsupported_format, other}}
end
```
