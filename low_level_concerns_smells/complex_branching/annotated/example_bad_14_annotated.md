# Code Smell: Complex branching

- **Smell name:** Complex branching
- **Expected smell location:** `handle_export_response/3`, inside the `case` that handles all response variants from `DataWarehouseClient.export/2`
- **Affected function(s):** `handle_export_response/3`
- **Short explanation:** `handle_export_response/3` maps every possible outcome of a data warehouse export API call — success, partial export, quota exceeded, schema mismatch, destination full, access denied, concurrent export conflict, invalid date range, and two transport errors — into a single `case` block with distinct side-effects per branch. The high cyclomatic complexity makes this function very difficult to read and test; any unhandled runtime error in a single branch (e.g., `QuotaTracker.record_exhaustion/3`) masks the actual response being handled and produces a confusing failure mode.

```elixir
defmodule Reporting.ExportOrchestrator do
  @moduledoc """
  Orchestrates report exports to external data warehouses, handling all
  warehouse API responses and coordinating retry, quota, and audit workflows.
  """

  alias Reporting.DataWarehouseClient
  alias Reporting.ExportJobStore
  alias Reporting.QuotaTracker
  alias Reporting.SchemaRegistry
  alias Reporting.RetryScheduler
  alias Notifications.AlertDispatcher
  alias Reporting.AuditLogger

  @retry_delay_seconds 300
  @quota_alert_threshold 0.90

  def run_export(job_id, export_config, requester_id) do
    with {:ok, job} <- ExportJobStore.fetch(job_id),
         :ok <- ExportJobStore.mark_running(job_id),
         {:ok, result} <- handle_export_response(job, export_config, requester_id),
         :ok <- ExportJobStore.mark_completed(job_id, result) do
      {:ok, result}
    else
      {:error, reason} = err ->
        ExportJobStore.mark_failed(job_id, reason)
        err
    end
  end

  # VALIDATION: SMELL START - Complex branching
  # VALIDATION: This is a smell because `handle_export_response/3` fuses all
  # possible response variants from `DataWarehouseClient.export/2` into one
  # `case` block. Ten branches — success, partial export with row-count
  # verification, quota exhaustion, schema mismatch, full destination,
  # access denial, concurrent conflict, invalid date range, timeout, and
  # generic error — each carry their own logic and side-effects such as
  # quota recording, schema correction queuing, alert dispatch, and retry
  # scheduling. The resulting cyclomatic complexity is very high; testing
  # each branch requires exercising the entire function, and a crash in any
  # one branch's side-effect (e.g., `AlertDispatcher.notify_ops/2`) hides
  # the underlying warehouse response, making root-cause analysis very hard.
  defp handle_export_response(job, export_config, requester_id) do
    case DataWarehouseClient.export(job.dataset, export_config) do
      {:ok, %{status: "completed", rows_written: rows, export_ref: ref, duration_ms: dur}} ->
        AuditLogger.log(:export_completed, requester_id, %{job_id: job.id, rows: rows, ref: ref})
        {:ok, %{export_ref: ref, rows_written: rows, duration_ms: dur}}

      {:ok, %{status: "partial", rows_written: rows, total_rows: total, export_ref: ref}} ->
        coverage = rows / total
        AuditLogger.log(:partial_export, requester_id, %{job_id: job.id, coverage: coverage})
        if coverage < 0.95 do
          AlertDispatcher.notify_ops(:partial_export_alert, %{job_id: job.id, coverage: coverage})
        end
        {:ok, %{export_ref: ref, rows_written: rows, partial: true, coverage: coverage}}

      {:ok, %{status: "failed", reason: "quota_exceeded", quota_limit: limit, resets_at: resets}} ->
        QuotaTracker.record_exhaustion(:warehouse_export, requester_id, resets)
        if limit > 0 do
          usage_ratio = 1.0
          if usage_ratio >= @quota_alert_threshold do
            AlertDispatcher.notify_ops(:quota_exhausted, %{job_id: job.id, resets_at: resets})
          end
        end
        RetryScheduler.schedule_after_reset(job.id, resets)
        {:error, {:quota_exceeded, resets}}

      {:ok, %{status: "failed", reason: "schema_mismatch", expected: exp, received: recv}} ->
        SchemaRegistry.queue_correction(job.dataset, exp, recv)
        AuditLogger.log(:schema_mismatch, requester_id, %{job_id: job.id, expected: exp, received: recv})
        {:error, {:schema_mismatch, %{expected: exp, received: recv}}}

      {:ok, %{status: "failed", reason: "destination_full", destination_id: did, used_bytes: used}} ->
        AlertDispatcher.notify_ops(:destination_full, %{destination_id: did, used_bytes: used})
        {:error, {:destination_full, did}}

      {:ok, %{status: "failed", reason: "access_denied", permission: perm}} ->
        AuditLogger.log(:export_access_denied, requester_id, %{job_id: job.id, permission: perm})
        {:error, {:access_denied, perm}}

      {:ok, %{status: "failed", reason: "concurrent_export", conflicting_job_id: cjid}} ->
        RetryScheduler.schedule(job.id, @retry_delay_seconds)
        {:error, {:concurrent_export, cjid}}

      {:ok, %{status: "failed", reason: "invalid_date_range", from: from, to: to}} ->
        {:error, {:invalid_date_range, %{from: from, to: to}}}

      {:ok, %{status: "failed", reason: other}} ->
        AuditLogger.log(:export_unknown_failure, requester_id, %{job_id: job.id, reason: other})
        {:error, {:export_failed, other}}

      {:error, %{reason: :timeout, elapsed_ms: ms}} ->
        RetryScheduler.schedule(job.id, @retry_delay_seconds)
        AuditLogger.log(:export_timeout, requester_id, %{job_id: job.id, elapsed_ms: ms})
        {:error, :warehouse_timeout}

      {:error, reason} ->
        AuditLogger.log(:warehouse_error, requester_id, %{job_id: job.id, reason: reason})
        {:error, :warehouse_error}
    end
  end
  # VALIDATION: SMELL END

  defp build_export_config(dataset, date_range, format) do
    %{dataset: dataset, from: date_range.from, to: date_range.to, format: format}
  end
end
```
