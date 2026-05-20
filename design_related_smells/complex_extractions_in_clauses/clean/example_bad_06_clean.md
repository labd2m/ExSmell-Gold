```elixir
defmodule Inventory.AdjustmentHandler do
  @moduledoc """
  Processes stock-level adjustments triggered by receiving, shrinkage,
  returns, or manual corrections. Writes to the ledger and emits
  domain events for downstream consumers.
  """

  require Logger

  alias Inventory.{
    StockLedger,
    EventBus,
    AuditLog,
    WarehouseRegistry,
    SkuCatalog
  }

  @large_negative_threshold -100
  @large_positive_threshold 500

  def apply(%Inventory.StockAdjustment{
        adjustment_id: adjustment_id,
        sku: sku,
        warehouse_id: warehouse_id,
        operator_id: operator_id,
        notes: notes,
        reason: :receiving,
        delta: delta
      })
      when delta > 0 do
    Logger.info("[AdjustmentHandler] Receiving #{delta} units of #{sku} at #{warehouse_id}")

    with {:ok, _} <- SkuCatalog.ensure_active(sku),
         {:ok, _} <- WarehouseRegistry.ensure_accepts_stock(warehouse_id),
         {:ok, new_level} <- StockLedger.increment(warehouse_id, sku, delta),
         :ok <- EventBus.publish(:stock_received, %{
                  adjustment_id: adjustment_id,
                  sku: sku,
                  warehouse_id: warehouse_id,
                  delta: delta,
                  new_level: new_level
                }),
         :ok <- AuditLog.write(:stock_adjustment, operator_id, %{
                  adjustment_id: adjustment_id,
                  reason: :receiving,
                  sku: sku,
                  delta: delta,
                  notes: notes
                }) do
      {:ok, :received, new_level}
    else
      {:error, :sku_inactive} ->
        Logger.warning("[AdjustmentHandler] Attempted to receive inactive SKU #{sku}")
        {:error, :sku_inactive}

      {:error, reason} ->
        Logger.error("[AdjustmentHandler] Receiving adjustment #{adjustment_id} failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  def apply(%Inventory.StockAdjustment{
        adjustment_id: adjustment_id,
        sku: sku,
        warehouse_id: warehouse_id,
        operator_id: operator_id,
        notes: notes,
        reason: :shrinkage,
        delta: delta
      })
      when delta < 0 and delta >= @large_negative_threshold do
    Logger.info("[AdjustmentHandler] Shrinkage of #{abs(delta)} units of #{sku} at #{warehouse_id}")

    with {:ok, current_level} <- StockLedger.fetch_level(warehouse_id, sku),
         :ok <- ensure_sufficient_stock(sku, current_level, delta),
         {:ok, new_level} <- StockLedger.decrement(warehouse_id, sku, abs(delta)),
         :ok <- EventBus.publish(:stock_shrinkage, %{
                  adjustment_id: adjustment_id,
                  sku: sku,
                  warehouse_id: warehouse_id,
                  delta: delta,
                  new_level: new_level
                }),
         :ok <- AuditLog.write(:stock_adjustment, operator_id, %{
                  adjustment_id: adjustment_id,
                  reason: :shrinkage,
                  sku: sku,
                  delta: delta,
                  notes: notes
                }) do
      {:ok, :shrinkage_recorded, new_level}
    else
      {:error, :insufficient_stock} = err ->
        Logger.warning("[AdjustmentHandler] Insufficient stock for shrinkage on #{sku}")
        err

      {:error, reason} ->
        {:error, reason}
    end
  end

  def apply(%Inventory.StockAdjustment{
        adjustment_id: adjustment_id,
        sku: sku,
        warehouse_id: warehouse_id,
        operator_id: operator_id,
        notes: notes,
        reason: :shrinkage,
        delta: delta
      })
      when delta < @large_negative_threshold do
    Logger.warning(
      "[AdjustmentHandler] Large shrinkage adjustment #{adjustment_id}: #{delta} units of #{sku}. " <>
        "Requires supervisor approval before posting."
    )

    Inventory.ApprovalQueue.submit(%{
      adjustment_id: adjustment_id,
      sku: sku,
      warehouse_id: warehouse_id,
      operator_id: operator_id,
      delta: delta,
      notes: notes,
      reason: :shrinkage
    })

    {:pending_approval, adjustment_id}
  end

  def apply(%Inventory.StockAdjustment{
        adjustment_id: adjustment_id,
        sku: sku,
        warehouse_id: warehouse_id,
        operator_id: operator_id,
        notes: notes,
        reason: :return,
        delta: delta
      })
      when delta > 0 do
    Logger.info("[AdjustmentHandler] Processing return of #{delta} units of #{sku} at #{warehouse_id}")

    restockable = SkuCatalog.restockable?(sku)

    with {:ok, new_level} <- maybe_restock(restockable, warehouse_id, sku, delta),
         :ok <- EventBus.publish(:stock_returned, %{
                  adjustment_id: adjustment_id,
                  sku: sku,
                  warehouse_id: warehouse_id,
                  delta: delta,
                  restocked: restockable,
                  new_level: new_level
                }),
         :ok <- AuditLog.write(:stock_adjustment, operator_id, %{
                  adjustment_id: adjustment_id,
                  reason: :return,
                  sku: sku,
                  delta: delta,
                  restockable: restockable,
                  notes: notes
                }) do
      {:ok, :return_processed, new_level}
    else
      {:error, reason} ->
        Logger.error("[AdjustmentHandler] Return #{adjustment_id} failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  def apply(%Inventory.StockAdjustment{adjustment_id: id, reason: reason}) do
    Logger.error("[AdjustmentHandler] Unhandled adjustment reason '#{reason}' on #{id}")
    {:error, :unhandled_reason}
  end

  # --- Private helpers ---

  defp ensure_sufficient_stock(_sku, current, delta) when current + delta >= 0, do: :ok
  defp ensure_sufficient_stock(_sku, _current, _delta), do: {:error, :insufficient_stock}

  defp maybe_restock(false, _warehouse, _sku, _delta), do: {:ok, 0}

  defp maybe_restock(true, warehouse_id, sku, delta) do
    StockLedger.increment(warehouse_id, sku, delta)
  end
end
```
