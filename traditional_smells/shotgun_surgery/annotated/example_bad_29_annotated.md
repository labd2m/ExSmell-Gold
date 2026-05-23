## Smell Metadata

- **Smell:** Shotgun Surgery
- **Expected Smell Location:** Functions `render/2`, `content_type/1`, `file_extension/1` in `Reporting.ExportRenderer`; `max_rows/1`, `supports_charts?/1` in `Reporting.ExportPolicy`; `storage_path/2` in `Reporting.ExportStorage`
- **Affected Functions:** See above (6 functions across 3 modules)
- **Explanation:** Adding a new export format (e.g., `:json`) requires scattered changes across three modules. Each module independently handles format-specific logic — rendering, row limits, and storage paths — with no centralized format registry, forcing multiple independent modifications for a single new format.

```elixir
defmodule Reporting.ExportRenderer do
  @moduledoc """
  Renders report datasets into the requested output format,
  applying format-specific encoding, structure, and page sizing.
  """

  # VALIDATION: SMELL START - Shotgun Surgery
  # VALIDATION: This is a smell because adding a new format (e.g., :json) requires
  # VALIDATION: new clauses in render/2, content_type/1, and file_extension/1 here,
  # VALIDATION: AND independent changes in Reporting.ExportPolicy and
  # VALIDATION: Reporting.ExportStorage.

  @spec render(atom(), map()) :: binary()
  def render(:pdf, report) do
    PdfGenerator.generate_binary("""
    <html>
      <head><title>#{report.title}</title></head>
      <body>
        <h1>#{report.title}</h1>
        <p>Generated: #{report.generated_at}</p>
        #{Enum.map_join(report.sections, "\n", &render_section/1)}
      </body>
    </html>
    """)
  end

  def render(:csv, report) do
    headers = report.columns |> Enum.map_join(",", & &1.label)
    rows    = report.rows    |> Enum.map_join("\n", fn row ->
      Enum.map_join(report.columns, ",", fn col ->
        to_string(Map.get(row, col.key, ""))
      end)
    end)
    "#{headers}\n#{rows}"
  end

  def render(:xlsx, report) do
    sheet = XlsxWriter.new_sheet(report.title)

    header_row = Enum.map(report.columns, & &1.label)
    XlsxWriter.add_row(sheet, header_row)

    Enum.each(report.rows, fn row ->
      values = Enum.map(report.columns, fn col -> Map.get(row, col.key, "") end)
      XlsxWriter.add_row(sheet, values)
    end)

    XlsxWriter.to_binary(sheet)
  end

  @spec content_type(atom()) :: String.t()
  def content_type(:pdf),  do: "application/pdf"
  def content_type(:csv),  do: "text/csv"
  def content_type(:xlsx), do: "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"

  @spec file_extension(atom()) :: String.t()
  def file_extension(:pdf),  do: "pdf"
  def file_extension(:csv),  do: "csv"
  def file_extension(:xlsx), do: "xlsx"

  # VALIDATION: SMELL END

  defp render_section(section) do
    "<section><h2>#{section.title}</h2><p>#{section.summary}</p></section>"
  end
end

defmodule Reporting.ExportPolicy do
  @moduledoc """
  Enforces export constraints such as maximum row counts and feature
  availability per output format to protect system performance.
  """

  # VALIDATION: SMELL START - Shotgun Surgery
  # VALIDATION: max_rows/1 and supports_charts?/1 require separate independent
  # VALIDATION: clauses for every new export format.

  @spec max_rows(atom()) :: pos_integer()
  def max_rows(:pdf),  do: 500
  def max_rows(:csv),  do: 1_000_000
  def max_rows(:xlsx), do: 1_048_576

  @spec supports_charts?(atom()) :: boolean()
  def supports_charts?(:pdf),  do: true
  def supports_charts?(:csv),  do: false
  def supports_charts?(:xlsx), do: true

  # VALIDATION: SMELL END

  def validate_export(format, row_count) do
    limit = max_rows(format)

    if row_count > limit do
      {:error, {:too_many_rows, %{requested: row_count, limit: limit, format: format}}}
    else
      :ok
    end
  end
end

defmodule Reporting.ExportStorage do
  @moduledoc """
  Manages file naming conventions and storage paths for generated report
  exports, routing files to format-appropriate object storage prefixes.
  """

  # VALIDATION: SMELL START - Shotgun Surgery
  # VALIDATION: storage_path/2 must also be updated per new format, representing yet
  # VALIDATION: another isolated change point disconnected from the others.

  @spec storage_path(atom(), String.t()) :: String.t()
  def storage_path(:pdf, report_id) do
    "reports/pdf/#{report_id}.pdf"
  end

  def storage_path(:csv, report_id) do
    "reports/csv/#{report_id}.csv"
  end

  def storage_path(:xlsx, report_id) do
    "reports/xlsx/#{report_id}.xlsx"
  end

  # VALIDATION: SMELL END

  def persist(format, report_id, binary_content) do
    path = storage_path(format, report_id)
    S3.put_object("acme-reports", path, binary_content,
      content_type: Reporting.ExportRenderer.content_type(format)
    )
  end

  def signed_url(format, report_id, expires_in \\ 3600) do
    path = storage_path(format, report_id)
    S3.presigned_url("acme-reports", path, expires_in: expires_in)
  end
end
```
