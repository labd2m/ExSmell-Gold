# Annotated Example 13

- **Smell name:** Unrelated multi-clause function
- **Expected smell location:** `ReportGenerator.generate/1`
- **Affected function(s):** `generate/1`
- **Short explanation:** `generate/1` mixes sales summary reports, user activity exports, and compliance audit reports — three completely different reporting domains — under one multi-clause function name, hindering independent documentation and making each clause's purpose implicit.

```elixir
defmodule ReportGenerator do
  @moduledoc """
  Generates business reports for internal stakeholders.
  Supports sales summaries, user activity exports, and compliance audit reports.
  """

  alias ReportGenerator.{
    SalesSummaryRequest,
    ActivityExportRequest,
    ComplianceAuditRequest,
    SalesDB,
    ActivityDB,
    AuditDB,
    CSVExporter,
    PDFRenderer,
    StorageBucket
  }

  require Logger

  @doc """
  Generate a business report from the given request struct.

  Accepts a `%SalesSummaryRequest{}`, `%ActivityExportRequest{}`, or
  `%ComplianceAuditRequest{}` and returns a download URL to the generated file.

  ## Examples

      iex> ReportGenerator.generate(%SalesSummaryRequest{from: ~D[2024-01-01], to: ~D[2024-03-31]})
      {:ok, "https://storage.example.com/reports/sales_2024Q1.pdf"}

  """
  # VALIDATION: SMELL START - Unrelated multi-clause function
  # VALIDATION: This is a smell because producing a sales summary, exporting
  # user activity, and generating a compliance audit are unrelated operations
  # with different data sources, output formats, and compliance implications.
  # Grouping them under a single `generate/1` function obscures each clause's
  # responsibility and prevents independent @doc annotations.

  def generate(%SalesSummaryRequest{from: from, to: to, region: region, format: format}) do
    Logger.info("Generating sales summary: #{from} to #{to}, region=#{region}")

    with {:ok, rows} <- SalesDB.fetch_summary(from, to, region),
         aggregated = aggregate_sales(rows),
         {:ok, content} <- render_report(format, "sales_summary", aggregated),
         filename = "sales_#{region}_#{from}_#{to}.#{format}",
         {:ok, url} <- StorageBucket.upload(filename, content) do
      {:ok, url}
    end
  end

  # generate user activity export for a given date range and team
  def generate(%ActivityExportRequest{
        from: from,
        to: to,
        team_id: team_id,
        include_deleted: include_deleted
      }) do
    Logger.info("Generating activity export for team #{team_id}")

    query_opts = [
      from: from,
      to: to,
      team_id: team_id,
      include_deleted: include_deleted
    ]

    with {:ok, events} <- ActivityDB.fetch_events(query_opts),
         rows = Enum.map(events, &format_activity_row/1),
         {:ok, csv_content} <- CSVExporter.export(activity_columns(), rows),
         filename = "activity_team#{team_id}_#{from}_#{to}.csv",
         {:ok, url} <- StorageBucket.upload(filename, csv_content) do
      {:ok, url}
    end
  end

  # generate compliance audit report for regulatory submission
  def generate(%ComplianceAuditRequest{
        audit_period: period,
        regulation: regulation,
        requested_by: requested_by
      }) do
    Logger.info(
      "Generating compliance audit: #{regulation}, period=#{period}, by=#{requested_by}"
    )

    with {:ok, events} <- AuditDB.fetch_for_period(period, regulation),
         :ok <- validate_audit_completeness(events, regulation),
         {:ok, signed_content} <- PDFRenderer.render_audit(events, regulation, requested_by),
         {:ok, hash} <- sign_document(signed_content),
         filename = "audit_#{regulation}_#{period}.pdf",
         {:ok, url} <- StorageBucket.upload_immutable(filename, signed_content, hash) do
      AuditDB.record_report_generated(regulation, period, requested_by, url)
      {:ok, url}
    end
  end

  # VALIDATION: SMELL END

  defp aggregate_sales(rows) do
    Enum.reduce(rows, %{total: 0, count: 0, by_product: %{}}, fn row, acc ->
      by_product = Map.update(acc.by_product, row.product_id, row.amount, &(&1 + row.amount))
      %{acc | total: acc.total + row.amount, count: acc.count + 1, by_product: by_product}
    end)
  end

  defp render_report(:pdf, template, data), do: PDFRenderer.render(template, data)
  defp render_report(:csv, _template, data), do: CSVExporter.export(sales_columns(), data)

  defp format_activity_row(event) do
    [event.user_id, event.action, event.resource, event.inserted_at]
  end

  defp activity_columns, do: ["User ID", "Action", "Resource", "Timestamp"]
  defp sales_columns, do: ["Region", "Product", "Revenue", "Units"]

  defp validate_audit_completeness(events, regulation) do
    required = ComplianceRules.required_event_types(regulation)
    present = MapSet.new(events, & &1.type)
    missing = MapSet.difference(MapSet.new(required), present)

    if MapSet.size(missing) == 0 do
      :ok
    else
      {:error, {:missing_event_types, MapSet.to_list(missing)}}
    end
  end

  defp sign_document(content) do
    {:ok, :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)}
  end
end
```
