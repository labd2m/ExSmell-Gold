# Annotated Example 05 — Complex Extractions in Clauses

## Metadata

| Field                  | Value                                                                                              |
|------------------------|----------------------------------------------------------------------------------------------------|
| **Smell name**         | Complex extractions in clauses                                                                     |
| **Expected location**  | `Reporting.Generator.generate/1`                                                                   |
| **Affected function**  | `generate/1`                                                                                       |
| **Short explanation**  | Each clause head extracts `report_type` (for clause selection), `period_start` (for the guard), and also `report_id`, `requester_id`, `filters`, `output_format`, and `title` — which appear nowhere in the clause expressions or guards and are solely consumed in the body. With three clauses, the head-level extraction of five body-only fields obscures which bindings actually determine which clause runs. |

---

```elixir
defmodule Reporting.Generator do
  @moduledoc """
  Entry point for on-demand report generation. Dispatches to the
  appropriate report builder based on report type, validates the
  requested time range, and stores the output artefact.
  """

  require Logger

  alias Reporting.{
    RevenueReportBuilder,
    InventoryReportBuilder,
    UserActivityReportBuilder,
    ArtifactStore,
    AuditLog,
    NotificationBus
  }

  @earliest_allowed_date ~D[2020-01-01]
  @max_period_days 366

  # VALIDATION: SMELL START - Complex extractions in clauses
  # VALIDATION: This is a smell because `report_id`, `requester_id`, `filters`,
  # `output_format`, and `title` are all extracted in the function head of every
  # clause but are exclusively used inside the body — they do not contribute to
  # clause selection or guard evaluation. Only `report_type` selects the clause
  # and `period_start` participates in the guard. With three clauses each
  # destructuring seven fields, identifying the true dispatch criteria demands
  # reading through the entire pattern of every clause.
  def generate(%Reporting.ReportRequest{
        report_id: report_id,
        requester_id: requester_id,
        filters: filters,
        output_format: output_format,
        title: title,
        report_type: :revenue,
        period_start: period_start
      })
      when period_start >= @earliest_allowed_date do
    Logger.info("[Generator] Building revenue report #{report_id} for #{requester_id}")

    period_days = Date.diff(Date.utc_today(), period_start)

    if period_days > @max_period_days do
      {:error, :period_too_long}
    else
      with {:ok, data} <- RevenueReportBuilder.build(filters, period_start),
           {:ok, artifact} <- ArtifactStore.persist(report_id, data, output_format),
           :ok <- AuditLog.write(:report_generated, requester_id, %{
                    report_id: report_id,
                    type: :revenue,
                    title: title
                  }),
           :ok <- NotificationBus.notify(requester_id, :report_ready, %{
                    report_id: report_id,
                    title: title,
                    download_url: artifact.url
                  }) do
        Logger.info("[Generator] Revenue report #{report_id} completed: #{artifact.url}")
        {:ok, artifact}
      else
        {:error, reason} ->
          Logger.error("[Generator] Revenue report #{report_id} failed: #{inspect(reason)}")
          AuditLog.write(:report_failed, requester_id, %{report_id: report_id, reason: reason})
          {:error, reason}
      end
    end
  end

  def generate(%Reporting.ReportRequest{
        report_id: report_id,
        requester_id: requester_id,
        filters: filters,
        output_format: output_format,
        title: title,
        report_type: :inventory,
        period_start: period_start
      })
      when period_start >= @earliest_allowed_date do
    Logger.info("[Generator] Building inventory report #{report_id} for #{requester_id}")

    warehouse_ids = Map.get(filters, :warehouse_ids, :all)

    with {:ok, data} <- InventoryReportBuilder.build(warehouse_ids, filters, period_start),
         {:ok, artifact} <- ArtifactStore.persist(report_id, data, output_format),
         :ok <- AuditLog.write(:report_generated, requester_id, %{
                  report_id: report_id,
                  type: :inventory,
                  title: title
                }),
         :ok <- NotificationBus.notify(requester_id, :report_ready, %{
                  report_id: report_id,
                  title: title,
                  download_url: artifact.url
                }) do
      {:ok, artifact}
    else
      {:error, reason} ->
        Logger.error("[Generator] Inventory report #{report_id} failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  def generate(%Reporting.ReportRequest{
        report_id: report_id,
        requester_id: requester_id,
        filters: filters,
        output_format: output_format,
        title: title,
        report_type: :user_activity,
        period_start: period_start
      })
      when period_start >= @earliest_allowed_date do
    Logger.info("[Generator] Building user-activity report #{report_id} for #{requester_id}")

    user_segment = Map.get(filters, :segment, :all)
    include_pii = Map.get(filters, :include_pii, false)

    with {:ok, _} <- maybe_check_pii_permission(requester_id, include_pii),
         {:ok, data} <- UserActivityReportBuilder.build(user_segment, filters, period_start),
         {:ok, artifact} <- ArtifactStore.persist(report_id, data, output_format),
         :ok <- AuditLog.write(:report_generated, requester_id, %{
                  report_id: report_id,
                  type: :user_activity,
                  title: title,
                  include_pii: include_pii
                }),
         :ok <- NotificationBus.notify(requester_id, :report_ready, %{
                  report_id: report_id,
                  title: title,
                  download_url: artifact.url
                }) do
      {:ok, artifact}
    else
      {:error, :pii_not_authorized} ->
        Logger.warning("[Generator] Unauthorized PII report attempt by #{requester_id}")
        {:error, :pii_not_authorized}

      {:error, reason} ->
        {:error, reason}
    end
  end
  # VALIDATION: SMELL END

  def generate(%Reporting.ReportRequest{
        report_id: report_id,
        period_start: period_start
      })
      when period_start < @earliest_allowed_date do
    Logger.warning("[Generator] Rejected report #{report_id}: period_start before allowed range")
    {:error, :period_out_of_range}
  end

  def generate(%Reporting.ReportRequest{report_id: report_id, report_type: unknown}) do
    Logger.error("[Generator] Unknown report type '#{unknown}' in request #{report_id}")
    {:error, :unknown_report_type}
  end

  # --- Private helpers ---

  defp maybe_check_pii_permission(_requester_id, false), do: {:ok, :no_pii}

  defp maybe_check_pii_permission(requester_id, true) do
    Reporting.PermissionChecker.check(requester_id, :pii_access)
  end
end
```
