# example_bad_13_clean

```elixir
defmodule Inventory.StockSyncAgent do
  @moduledoc """
  Pushes stock adjustment events to the warehouse management system and
  reconciles the internal ledger based on the WMS response.
  """

  alias Inventory.WarehouseSystemClient
  alias Inventory.StockLedger
  alias Inventory.QuarantineRegistry
  alias Inventory.LotTracker
  alias Inventory.RetryQueue
  alias Inventory.AuditLogger

  @busy_retry_seconds 120
  @max_partial_variance 0.05

  def sync_adjustment(warehouse_id, adjustment, operator_id) do
    with :ok <- StockLedger.lock_sku(warehouse_id, adjustment.sku),
         {:ok, result} <- apply_sync_response(warehouse_id, adjustment, operator_id),
         :ok <- StockLedger.unlock_sku(warehouse_id, adjustment.sku) do
      {:ok, result}
    end
  end

  defp apply_sync_response(warehouse_id, adjustment, operator_id) do
    case WarehouseSystemClient.push_adjustment(adjustment, warehouse_id) do
      {:ok, %{status: "acknowledged", wms_ref: ref, applied_qty: qty}} ->
        StockLedger.record_adjustment(warehouse_id, adjustment.sku, qty, ref)
        AuditLogger.log(:stock_adjusted, warehouse_id, %{sku: adjustment.sku, qty: qty, ref: ref})
        {:ok, %{status: :acknowledged, wms_ref: ref, applied_qty: qty}}

      {:ok, %{status: "partial", wms_ref: ref, accepted_qty: aqty, requested_qty: rqty}} ->
        variance = abs(aqty - rqty) / rqty
        StockLedger.record_adjustment(warehouse_id, adjustment.sku, aqty, ref)
        if variance > @max_partial_variance do
          AuditLogger.log(:partial_variance_alert, warehouse_id, %{sku: adjustment.sku, variance: variance})
        end
        {:ok, %{status: :partial, applied_qty: aqty, variance: variance}}

      {:ok, %{status: "rejected", reason: "negative_stock", current_qty: current}} ->
        AuditLogger.log(:negative_stock_rejection, warehouse_id, %{sku: adjustment.sku, current: current})
        {:error, {:negative_stock, current}}

      {:ok, %{status: "rejected", reason: "location_locked", location_id: lid, locked_by: by}} ->
        AuditLogger.log(:location_locked_rejection, warehouse_id, %{location_id: lid, locked_by: by})
        RetryQueue.schedule(adjustment, @busy_retry_seconds, operator_id)
        {:error, {:location_locked, lid}}

      {:ok, %{status: "rejected", reason: "expired_lot", lot_number: lot, expired_at: exp}} ->
        LotTracker.expire(warehouse_id, lot, exp)
        AuditLogger.log(:expired_lot_rejection, warehouse_id, %{lot: lot, expired_at: exp})
        {:error, {:expired_lot, lot}}

      {:ok, %{status: "rejected", reason: "quarantine_hold", hold_id: hid, reason: hreason}} ->
        QuarantineRegistry.hold(warehouse_id, adjustment.sku, %{hold_id: hid, reason: hreason})
        AuditLogger.log(:quarantine_hold, warehouse_id, %{sku: adjustment.sku, hold_id: hid})
        {:error, {:quarantine_hold, hid}}

      {:ok, %{status: "rejected", reason: other_reason}} ->
        AuditLogger.log(:unknown_rejection, warehouse_id, %{reason: other_reason, sku: adjustment.sku})
        {:error, {:rejected, other_reason}}

      {:ok, %{status: "system_busy", retry_after: secs}} ->
        RetryQueue.schedule(adjustment, secs, operator_id)
        {:error, {:system_busy, secs}}

      {:error, %{reason: :timeout}} ->
        RetryQueue.schedule(adjustment, @busy_retry_seconds, operator_id)
        {:error, :wms_timeout}

      {:error, reason} ->
        AuditLogger.log(:wms_error, warehouse_id, %{reason: reason, sku: adjustment.sku})
        {:error, :wms_error}
    end
  end

  defp build_adjustment_ref(warehouse_id, sku) do
    "adj-#{warehouse_id}-#{sku}-#{System.system_time(:millisecond)}"
  end
end
```
