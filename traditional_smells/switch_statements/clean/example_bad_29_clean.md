```elixir
defmodule ReportExporter do
  @moduledoc """
  Handles exporting of business reports in multiple formats.
  Supports PDF, CSV, XLSX and JSON output, managing content
  negotiation headers and file naming conventions.
  """

  alias ReportExporter.{
    Report,
    PdfRenderer,
    CsvRenderer,
    XlsxRenderer,
    JsonRenderer,
    StorageBackend
  }

  @type export_format :: :pdf | :csv | :xlsx | :json

  @spec export(Report.t(), export_format(), keyword()) ::
          {:ok, String.t()} | {:error, String.t()}
  def export(%Report{} = report, format, opts \\ []) do
    with {:ok, renderer} <- resolve_renderer(format),
         {:ok, data} <- renderer.render(report, opts),
         filename = build_filename(report, format),
         {:ok, url} <- StorageBackend.upload(filename, data, content_type(format)) do
      {:ok, url}
    end
  end

  @spec download_headers(export_format(), String.t()) :: [{String.t(), String.t()}]
  def download_headers(format, report_name) do
    filename = "#{report_name}.#{file_extension(format)}"

    [
      {"content-type", content_type(format)},
      {"content-disposition", ~s(attachment; filename="#{filename}")}
    ]
  end

  @spec build_filename(Report.t(), export_format()) :: String.t()
  defp build_filename(%Report{slug: slug}, format) do
    timestamp = DateTime.utc_now() |> DateTime.to_unix()
    "#{slug}_#{timestamp}.#{file_extension(format)}"
  end

  @spec resolve_renderer(export_format()) :: {:ok, module()} | {:error, String.t()}
  defp resolve_renderer(format) do
    case format do
      :pdf  -> {:ok, PdfRenderer}
      :csv  -> {:ok, CsvRenderer}
      :xlsx -> {:ok, XlsxRenderer}
      :json -> {:ok, JsonRenderer}
      _     -> {:error, "unsupported export format: #{format}"}
    end
  end





  @spec content_type(export_format()) :: String.t()
  def content_type(format) do
    case format do
      :pdf  -> "application/pdf"
      :csv  -> "text/csv"
      :xlsx -> "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
      :json -> "application/json"
    end
  end






  @spec file_extension(export_format()) :: String.t()
  def file_extension(format) do
    case format do
      :pdf  -> "pdf"
      :csv  -> "csv"
      :xlsx -> "xlsx"
      :json -> "json"
    end
  end


  @spec supported_formats() :: [export_format()]
  def supported_formats, do: [:pdf, :csv, :xlsx, :json]

  @spec valid_format?(atom()) :: boolean()
  def valid_format?(format), do: format in supported_formats()

  @spec list_exports(String.t()) :: {:ok, [map()]} | {:error, String.t()}
  def list_exports(report_slug) do
    case StorageBackend.list(prefix: report_slug) do
      {:ok, files} ->
        exports =
          Enum.map(files, fn file ->
            %{
              url: file.url,
              size_bytes: file.size,
              uploaded_at: file.created_at
            }
          end)

        {:ok, exports}

      {:error, reason} ->
        {:error, "could not list exports: #{inspect(reason)}"}
    end
  end
end
```
