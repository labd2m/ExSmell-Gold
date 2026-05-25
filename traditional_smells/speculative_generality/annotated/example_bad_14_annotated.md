# Example Bad 14 — Annotated

## Metadata

- **Smell Name**: Speculative Generality
- **Expected Smell Location**: `Reporting.ExcelExporter` (module definition)
- **Affected Function(s)**: entire `Reporting.ExcelExporter` module
- **Explanation**: `Reporting.ExcelExporter` was created speculatively to handle Excel
  (.xlsx) report generation as an anticipated future export format. The main module
  `Reporting.DataExporter` only produces CSV and JSON outputs and never calls any
  function from `ExcelExporter`. The module is dead code — fully implemented but
  completely unreferenced — that adds maintenance overhead with no benefit.

## Code

```elixir
defmodule Reporting.DataExporter do
  @moduledoc """
  Exports report datasets in multiple formats for downstream consumption.
  Supports CSV and JSON export with configurable column mappings and
  optional column filtering.
  """

  alias Reporting.{ReportRun, ExportLog, Repo}

  @export_dir "priv/exports"

  def export_csv(report_run_id, opts \\ []) do
    run     = Repo.get!(ReportRun, report_run_id)
    columns = Keyword.get(opts, :columns, default_columns(run.type))
    rows    = run.data

    header = Enum.join(columns, ",")

    body =
      Enum.map(rows, fn row ->
        columns
        |> Enum.map(&to_string(Map.get(row, &1, "")))
        |> Enum.join(",")
      end)
      |> Enum.join("\n")

    content  = header <> "\n" <> body
    filename = "report_#{report_run_id}_#{Date.utc_today()}.csv"
    path     = Path.join(@export_dir, filename)

    File.write!(path, content)
    log_export(report_run_id, :csv, path)

    {:ok, path}
  end

  def export_json(report_run_id, opts \\ []) do
    run     = Repo.get!(ReportRun, report_run_id)
    columns = Keyword.get(opts, :columns, default_columns(run.type))

    filtered_data =
      Enum.map(run.data, fn row ->
        Map.take(row, columns)
      end)

    content  = Jason.encode!(%{report_id: report_run_id, rows: filtered_data})
    filename = "report_#{report_run_id}_#{Date.utc_today()}.json"
    path     = Path.join(@export_dir, filename)

    File.write!(path, content)
    log_export(report_run_id, :json, path)

    {:ok, path}
  end

  def list_exports(report_run_id) do
    ExportLog
    |> Repo.all()
    |> Enum.filter(&(&1.report_run_id == report_run_id))
    |> Enum.sort_by(& &1.exported_at, {:desc, DateTime})
  end

  def export_summary do
    ExportLog
    |> Repo.all()
    |> Enum.group_by(& &1.format)
    |> Map.new(fn {format, logs} -> {format, length(logs)} end)
  end

  # --- Private ---

  defp default_columns(:sales),     do: [:date, :amount, :product, :rep]
  defp default_columns(:inventory), do: [:sku, :name, :quantity, :location]
  defp default_columns(:users),     do: [:id, :email, :name, :created_at]
  defp default_columns(_),          do: [:id, :value, :timestamp]

  defp log_export(report_run_id, format, path) do
    Repo.insert!(%ExportLog{
      report_run_id: report_run_id,
      format:        format,
      file_path:     path,
      exported_at:   DateTime.utc_now()
    })
  end
end

# VALIDATION: SMELL START - Speculative Generality
# VALIDATION: This is a smell because `Reporting.ExcelExporter` was implemented
# speculatively to support .xlsx exports as a future format. The main module
# `Reporting.DataExporter` exports only CSV and JSON and never calls any function
# defined here. The entire module is dead code—fully implemented but never
# referenced—adding maintenance burden without delivering any value.
defmodule Reporting.ExcelExporter do
  @moduledoc """
  Exports report datasets as Excel (.xlsx) workbooks.
  Intended to provide formatted spreadsheet output for business users
  who prefer Excel over CSV for downstream analysis.
  """

  alias Reporting.{ReportRun, Repo}

  @export_dir "priv/exports"
  @sheet_name "Report"

  def export(report_run_id, opts \\ []) do
    run     = Repo.get!(ReportRun, report_run_id)
    columns = Keyword.get(opts, :columns, default_columns(run.type))
    title   = Keyword.get(opts, :title, "Report #{report_run_id}")

    workbook = build_workbook(title, columns, run.data)
    filename = "report_#{report_run_id}_#{Date.utc_today()}.xlsx"
    path     = Path.join(@export_dir, filename)

    write_workbook(workbook, path)
    {:ok, path}
  end

  def export_with_summary(report_run_id) do
    run       = Repo.get!(ReportRun, report_run_id)
    columns   = default_columns(run.type)
    workbook  = build_workbook("Report #{report_run_id}", columns, run.data)
    _summary  = build_summary_sheet(run.data)

    filename = "report_#{report_run_id}_summary_#{Date.utc_today()}.xlsx"
    path     = Path.join(@export_dir, filename)

    write_workbook(workbook, path)
    {:ok, path}
  end

  # --- Private ---

  defp build_workbook(title, columns, rows) do
    %{title: title, sheet: @sheet_name, columns: columns, rows: rows}
  end

  defp build_summary_sheet(rows) do
    %{total_rows: length(rows)}
  end

  defp write_workbook(workbook, path) do
    File.write!(path, :erlang.term_to_binary(workbook))
  end

  defp default_columns(:sales),     do: [:date, :amount, :product, :rep]
  defp default_columns(:inventory), do: [:sku, :name, :quantity, :location]
  defp default_columns(_),          do: [:id, :value, :timestamp]
end
# VALIDATION: SMELL END
```
