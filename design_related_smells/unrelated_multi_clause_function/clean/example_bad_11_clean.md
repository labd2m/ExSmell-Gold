```elixir
defmodule InventoryManager do
  @moduledoc """
  Manages inventory operations across warehouse locations.
  Handles stock movements including replenishments, inter-warehouse
  transfers, and product write-offs.
  """

  alias InventoryManager.{
    ReplenishmentEvent,
    TransferOrder,
    WriteOffEvent,
    StockLedger,
    WarehouseStore,
    AuditLog
  }

  require Logger

  @doc """
  Apply an inventory event to update stock levels.

  Accepts a `%ReplenishmentEvent{}`, `%TransferOrder{}`, or `%WriteOffEvent{}`
  and updates the relevant stock records accordingly.

  ## Examples

      iex> InventoryManager.apply(%ReplenishmentEvent{sku: "ABC-001", qty: 100, warehouse_id: 1})
      {:ok, %StockBalance{qty: 100}}

  """

  def apply(%ReplenishmentEvent{
        sku: sku,
        qty: qty,
        warehouse_id: warehouse_id,
        purchase_order_id: po_id
      })
      when qty > 0 do
    with {:ok, current} <- WarehouseStore.get_balance(sku, warehouse_id),
         new_qty = current.qty + qty,
         {:ok, updated} <- WarehouseStore.set_balance(sku, warehouse_id, new_qty),
         :ok <-
           StockLedger.record(%{
             type: :replenishment,
             sku: sku,
             qty: qty,
             warehouse_id: warehouse_id,
             reference: po_id,
             recorded_at: DateTime.utc_now()
           }),
         :ok <- AuditLog.append(:replenishment, %{sku: sku, qty: qty, warehouse_id: warehouse_id}) do
      Logger.info("Replenished #{qty} units of #{sku} at warehouse #{warehouse_id}")
      {:ok, updated}
    end
  end

  # apply warehouse-to-warehouse transfer order
  def apply(%TransferOrder{
        sku: sku,
        qty: qty,
        from_warehouse: from_wh,
        to_warehouse: to_wh,
        order_id: order_id
      })
      when qty > 0 and from_wh != to_wh do
    with {:ok, source} <- WarehouseStore.get_balance(sku, from_wh),
         :ok <- validate_sufficient_stock(source.qty, qty),
         {:ok, _} <- WarehouseStore.set_balance(sku, from_wh, source.qty - qty),
         {:ok, dest} <- WarehouseStore.get_balance(sku, to_wh),
         {:ok, updated} <- WarehouseStore.set_balance(sku, to_wh, dest.qty + qty),
         :ok <-
           StockLedger.record(%{
             type: :transfer,
             sku: sku,
             qty: qty,
             from_warehouse: from_wh,
             to_warehouse: to_wh,
             reference: order_id,
             recorded_at: DateTime.utc_now()
           }) do
      Logger.info("Transferred #{qty}x #{sku} from #{from_wh} to #{to_wh}")
      {:ok, updated}
    end
  end

  # apply product write-off due to damage or expiry
  def apply(%WriteOffEvent{
        sku: sku,
        qty: qty,
        warehouse_id: warehouse_id,
        reason: reason
      })
      when reason in [:damaged, :expired, :theft, :administrative] do
    with {:ok, current} <- WarehouseStore.get_balance(sku, warehouse_id),
         :ok <- validate_sufficient_stock(current.qty, qty),
         new_qty = max(0, current.qty - qty),
         {:ok, updated} <- WarehouseStore.set_balance(sku, warehouse_id, new_qty),
         :ok <-
           StockLedger.record(%{
             type: :write_off,
             sku: sku,
             qty: qty,
             warehouse_id: warehouse_id,
             reason: reason,
             recorded_at: DateTime.utc_now()
           }),
         :ok <- AuditLog.append(:write_off, %{sku: sku, qty: qty, reason: reason}) do
      Logger.warning("Wrote off #{qty} units of #{sku} at warehouse #{warehouse_id}: #{reason}")
      {:ok, updated}
    end
  end


  defp validate_sufficient_stock(available, requested) when available >= requested, do: :ok
  defp validate_sufficient_stock(_, _), do: {:error, :insufficient_stock}
end
```
