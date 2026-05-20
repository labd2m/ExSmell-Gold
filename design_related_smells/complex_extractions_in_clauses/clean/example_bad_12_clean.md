```elixir
defmodule Warehouse.ReceivingDock do
  @moduledoc """
  Manages inbound goods receiving at warehouse docks. Validates deliveries
  against purchase orders, applies quality checks, handles quarantine
  for damaged goods, and triggers putaway workflows.
  """

  require Logger

  alias Warehouse.{
    PurchaseOrderRegistry,
    StockPutaway,
    QuarantineZone,
    SupplierScorecard,
    ReceivingLedger,
    DockScheduler,
    AuditLog
  }

  @bulk_receiving_threshold 1_000
  @minimum_acceptable_quantity 1

  def accept_delivery(%Warehouse.Delivery{
        delivery_id: delivery_id,
        purchase_order_id: purchase_order_id,
        supplier_id: supplier_id,
        sku: sku,
        dock_id: dock_id,
        condition: :good,
        quantity: quantity
      })
      when quantity >= @minimum_acceptable_quantity and quantity < @bulk_receiving_threshold do
    Logger.info(
      "[ReceivingDock] Accepting standard delivery #{delivery_id}: #{quantity} units of #{sku} " <>
        "from supplier #{supplier_id} at dock #{dock_id}"
    )

    with {:ok, po} <- PurchaseOrderRegistry.fetch(purchase_order_id),
         :ok <- validate_against_po(po, sku, quantity),
         {:ok, putaway_task} <- StockPutaway.schedule(delivery_id, sku, quantity, dock_id),
         :ok <- ReceivingLedger.record(delivery_id, :accepted, %{
                  sku: sku,
                  quantity: quantity,
                  purchase_order_id: purchase_order_id,
                  putaway_task_id: putaway_task.id
                }),
         :ok <- PurchaseOrderRegistry.mark_line_received(purchase_order_id, sku, quantity),
         :ok <- AuditLog.write(:delivery_accepted, supplier_id, %{
                  delivery_id: delivery_id,
                  dock_id: dock_id,
                  quantity: quantity
                }) do
      {:ok, :accepted, putaway_task.id}
    else
      {:error, :po_not_found} ->
        Logger.warning("[ReceivingDock] No PO found for delivery #{delivery_id}")
        {:error, :po_not_found}

      {:error, :quantity_exceeds_po} ->
        Logger.warning("[ReceivingDock] Quantity #{quantity} exceeds PO for #{sku}")
        {:error, :quantity_exceeds_po}

      {:error, reason} ->
        Logger.error("[ReceivingDock] Acceptance failed for #{delivery_id}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  def accept_delivery(%Warehouse.Delivery{
        delivery_id: delivery_id,
        purchase_order_id: purchase_order_id,
        supplier_id: supplier_id,
        sku: sku,
        dock_id: dock_id,
        condition: :good,
        quantity: quantity
      })
      when quantity >= @bulk_receiving_threshold do
    Logger.info(
      "[ReceivingDock] Bulk delivery #{delivery_id}: #{quantity} units of #{sku} " <>
        "from #{supplier_id}. Initiating staged putaway."
    )

    batches = ceil(quantity / 100)

    with {:ok, po} <- PurchaseOrderRegistry.fetch(purchase_order_id),
         :ok <- validate_against_po(po, sku, quantity),
         {:ok, task_ids} <- StockPutaway.schedule_bulk(delivery_id, sku, quantity, dock_id, batches),
         :ok <- ReceivingLedger.record(delivery_id, :bulk_accepted, %{
                  sku: sku,
                  quantity: quantity,
                  batches: batches,
                  purchase_order_id: purchase_order_id
                }),
         :ok <- PurchaseOrderRegistry.mark_line_received(purchase_order_id, sku, quantity),
         :ok <- AuditLog.write(:bulk_delivery_accepted, supplier_id, %{
                  delivery_id: delivery_id,
                  dock_id: dock_id,
                  quantity: quantity,
                  batches: batches
                }) do
      {:ok, :bulk_accepted, task_ids}
    else
      {:error, reason} ->
        Logger.error("[ReceivingDock] Bulk acceptance failed for #{delivery_id}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  def accept_delivery(%Warehouse.Delivery{
        delivery_id: delivery_id,
        purchase_order_id: purchase_order_id,
        supplier_id: supplier_id,
        sku: sku,
        dock_id: dock_id,
        condition: :damaged,
        quantity: quantity
      })
      when quantity >= @minimum_acceptable_quantity do
    Logger.warning(
      "[ReceivingDock] Damaged delivery #{delivery_id}: #{quantity} units of #{sku} " <>
        "from #{supplier_id} at dock #{dock_id}. Routing to quarantine."
    )

    with {:ok, quarantine_ref} <- QuarantineZone.admit(delivery_id, sku, quantity, dock_id),
         :ok <- ReceivingLedger.record(delivery_id, :quarantined, %{
                  sku: sku,
                  quantity: quantity,
                  purchase_order_id: purchase_order_id,
                  quarantine_ref: quarantine_ref
                }),
         :ok <- SupplierScorecard.record_damaged_delivery(supplier_id, delivery_id, quantity),
         :ok <- AuditLog.write(:delivery_quarantined, supplier_id, %{
                  delivery_id: delivery_id,
                  dock_id: dock_id,
                  quarantine_ref: quarantine_ref
                }) do
      {:ok, :quarantined, quarantine_ref}
    else
      {:error, reason} ->
        Logger.error("[ReceivingDock] Quarantine failed for #{delivery_id}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  def accept_delivery(%Warehouse.Delivery{
        delivery_id: delivery_id,
        purchase_order_id: purchase_order_id,
        supplier_id: supplier_id,
        sku: sku,
        dock_id: dock_id,
        condition: :rejected,
        quantity: quantity
      })
      when quantity >= @minimum_acceptable_quantity do
    Logger.warning(
      "[ReceivingDock] Rejecting delivery #{delivery_id}: #{quantity} units of #{sku} " <>
        "from #{supplier_id}"
    )

    with :ok <- DockScheduler.schedule_return(dock_id, delivery_id, supplier_id),
         :ok <- ReceivingLedger.record(delivery_id, :rejected, %{
                  sku: sku,
                  quantity: quantity,
                  purchase_order_id: purchase_order_id
                }),
         :ok <- SupplierScorecard.record_rejection(supplier_id, delivery_id),
         :ok <- AuditLog.write(:delivery_rejected, supplier_id, %{
                  delivery_id: delivery_id,
                  dock_id: dock_id,
                  quantity: quantity
                }) do
      {:ok, :rejected, delivery_id}
    else
      {:error, reason} ->
        Logger.error("[ReceivingDock] Rejection workflow failed for #{delivery_id}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  def accept_delivery(%Warehouse.Delivery{delivery_id: id, quantity: q})
      when q < @minimum_acceptable_quantity do
    Logger.error("[ReceivingDock] Delivery #{id} has invalid quantity: #{q}")
    {:error, :invalid_quantity}
  end

  def accept_delivery(%Warehouse.Delivery{delivery_id: id, condition: cond}) do
    Logger.error("[ReceivingDock] Unknown delivery condition '#{cond}' on #{id}")
    {:error, :unknown_condition}
  end

  # --- Private helpers ---

  defp validate_against_po(%{lines: lines}, sku, quantity) do
    case Enum.find(lines, &(&1.sku == sku)) do
      nil -> {:error, :sku_not_on_po}
      line when line.outstanding_quantity >= quantity -> :ok
      _ -> {:error, :quantity_exceeds_po}
    end
  end
end
```
