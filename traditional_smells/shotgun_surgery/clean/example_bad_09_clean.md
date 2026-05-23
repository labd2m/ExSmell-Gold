```elixir
defmodule Reports.Exporter do
  @moduledoc """
  Handles report generation and export across multiple output formats.
  Manages rendering, branding, page configuration, and cache invalidation
  policies for each supported export format.
  """

  alias Reports.{ReportData, PdfRenderer, CsvRenderer, XlsxRenderer, ExportCache, BrandingConfig}

  def export(report_id, format, requested_by) do
    cache_key = "report:#{report_id}:#{format}"

    case ExportCache.get(cache_key) do
      {:hit, data} ->
        {:ok, data}

      :miss ->
        with {:ok, report} <- ReportData.fetch(report_id),
             :ok           <- authorize_export(requested_by, report),
             {:ok, output} <- generate_export(report, format) do
          ttl = get_cache_ttl(format)
          ExportCache.put(cache_key, output, ttl: ttl)
          {:ok, output}
        end
    end
  end

  defp generate_export(report, format) do
    page_config = get_page_config(format)
    header      = render_header(report, format)
    branded     = apply_branding(report, format)

    case format do
      :pdf  -> PdfRenderer.render(branded, header, page_config)
      :csv  -> CsvRenderer.render(branded, header, page_config)
      :xlsx -> XlsxRenderer.render(branded, header, page_config)
      _     -> {:error, :unsupported_format}
    end
  end

  defp authorize_export(user, report) do
    if report.owner_id == user.id or :admin in user.roles do
      :ok
    else
      {:error, :unauthorized}
    end
  end

  def render_header(report, :pdf) do
    %{
      title:       report.title,
      subtitle:    "Generated #{Date.utc_today()}",
      logo:        true,
      page_header: true,
      font_size:   14
    }
  end

  def render_header(report, :csv) do
    columns = Enum.map(report.columns, & &1.label)
    %{columns: columns, include_meta: false}
  end

  def render_header(report, :xlsx) do
    %{
      title:      report.title,
      created_by: report.created_by,
      sheet_name: String.slice(report.title, 0, 31),
      freeze_row: true
    }
  end

  def get_page_config(:pdf) do
    %{page_size: :a4, orientation: :portrait, margin_mm: 15, dpi: 150}
  end

  def get_page_config(:csv) do
    %{delimiter: ",", encoding: :utf8, line_ending: :crlf, quote_strings: true}
  end

  def get_page_config(:xlsx) do
    %{row_height: 20, column_auto_width: true, freeze_panes: {1, 0}, grid_lines: true}
  end

  def apply_branding(report, :pdf) do
    brand = BrandingConfig.get()
    %{report | logo_url: brand.logo_url, color_scheme: brand.primary_color, watermark: brand.watermark}
  end

  def apply_branding(report, :csv) do
    %{report | metadata: Map.put(report.metadata, :export_source, "AppReports")}
  end

  def apply_branding(report, :xlsx) do
    brand = BrandingConfig.get()
    %{report | tab_color: brand.primary_color, header_bg: brand.secondary_color}
  end

  def get_cache_ttl(:pdf),  do: 3_600
  def get_cache_ttl(:csv),  do: 900
  def get_cache_ttl(:xlsx), do: 1_800
  def get_cache_ttl(_),     do: 600

  def list_formats, do: [:pdf, :csv, :xlsx]

  def purge_cache(report_id) do
    list_formats()
    |> Enum.each(fn fmt ->
      ExportCache.delete("report:#{report_id}:#{fmt}")
    end)
    :ok
  end

  def available_formats_for(user) do
    base = list_formats()
    if :admin in user.roles, do: base, else: List.delete(base, :xlsx)
  end
end
```
