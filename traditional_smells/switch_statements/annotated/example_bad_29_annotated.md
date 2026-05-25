# Annotated Example — Switch Statements

## Metadata

- **Smell name:** Switch Statements
- **Expected smell location:** `ReportExporter.content_type/1` and `ReportExporter.file_extension/1`
- **Affected functions:** `content_type/1`, `file_extension/1`
- **Short explanation:** The same `case` branching over export format (`:pdf`, `:csv`, `:xlsx`, `:json`) is duplicated in both `content_type/1` and `file_extension/1`. Introducing a new format requires editing both functions.

---

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

  # VALIDATION: SMELL START - Switch Statements
  # VALIDATION: This is a smell because the same case branching on `format`
  # also appears in `file_extension/1` below. Both enumerate :pdf, :csv, :xlsx,
  # :json — adding a new format means touching both case blocks independently.
  @spec content_type(export_format()) :: String.t()
  def content_type(format) do
    case format do
      :pdf  -> "application/pdf"
      :csv  -> "text/csv"
      :xlsx -> "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
      :json -> "application/json"
    end
  end
  # VALIDATION: SMELL END

  # VALIDATION: SMELL START - Switch Statements
  # VALIDATION: This is a smell because the same case branching on `format`
  # already appeared in `content_type/1` above. The format atoms :pdf, :csv,
  # :xlsx, :json are fully repeated here, requiring parallel maintenance.
  @spec file_extension(export_format()) :: String.t()
  def file_extension(format) do
    case format do
      :pdf  -> "pdf"
      :csv  -> "csv"
      :xlsx -> "xlsx"
      :json -> "json"
    end
  end
  # VALIDATION: SMELL END

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
