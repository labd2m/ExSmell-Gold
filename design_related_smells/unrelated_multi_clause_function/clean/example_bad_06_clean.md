```elixir
defmodule InventoryManager do
  @moduledoc """
  Manages inventory movements and stock level adjustments across warehouses.
  """

  alias InventoryManager.{
    GoodsReceipt,
    DamageWriteOff,
    WarehouseTransfer,
    Repo,
    AuditLog,
    StockLedger
  }

  @doc """
  Applies an inventory movement to the stock ledger.

  ## Examples

      iex> InventoryManager.apply(%GoodsReceipt{po_number: "PO-1001", items: [...]})
      {:ok, %{received: 5, skus: ["SKU-001", "SKU-002"]}}

  """


  def apply(%GoodsReceipt{
        po_number: po_number,
        received_by: user_id,
        items: items
      }) do
    with {:ok, purchase_order} <- Repo.find_purchase_order(po_number),
         :pending <- purchase_order.status do
      results =
        Enum.map(items, fn %{sku: sku, quantity: qty, unit_cost: cost} ->
          StockLedger.credit(sku, purchase_order.warehouse_id, qty, cost, :goods_receipt)
        end)

      received_skus = Enum.map(items, & &1.sku)

      AuditLog.record(:goods_receipt, %{
        po_number: po_number,
        user_id: user_id,
        items: items,
        timestamp: DateTime.utc_now()
      })

      Repo.update_po_status(po_number, :received)

      {:ok, %{received: length(results), skus: received_skus}}
    else
      status when is_atom(status) -> {:error, {:invalid_po_status, status}}
      {:error, reason} -> {:error, reason}
    end
  end

  # writes off inventory lost to damage or spoilage
  def apply(%DamageWriteOff{
        sku: sku,
        warehouse_id: warehouse_id,
        quantity: quantity,
        reason: reason,
        authorized_by: approver_id
      })
      when is_binary(reason) and byte_size(reason) > 0 do
    with {:ok, approver} <- Repo.find_user(approver_id),
         true <- :manager in approver.roles,
         {:ok, current_stock} <- StockLedger.get_stock(sku, warehouse_id),
         true <- current_stock.quantity >= quantity do
      StockLedger.debit(sku, warehouse_id, quantity, :damage_write_off)

      AuditLog.record(:damage_write_off, %{
        sku: sku,
        warehouse_id: warehouse_id,
        quantity: quantity,
        reason: reason,
        authorized_by: approver_id,
        timestamp: DateTime.utc_now()
      })

      {:ok, %{written_off: quantity, remaining_stock: current_stock.quantity - quantity}}
    else
      false -> {:error, :unauthorized_or_insufficient_stock}
      {:error, reason} -> {:error, reason}
    end
  end

  # transfers stock from one warehouse to another
  def apply(%WarehouseTransfer{
        sku: sku,
        from_warehouse: from_id,
        to_warehouse: to_id,
        quantity: quantity,
        requested_by: user_id
      })
      when from_id != to_id do
    with {:ok, source_stock} <- StockLedger.get_stock(sku, from_id),
         true <- source_stock.quantity >= quantity,
         {:ok, _} <- StockLedger.debit(sku, from_id, quantity, :transfer_out),
         {:ok, _} <- StockLedger.credit(sku, to_id, quantity, source_stock.unit_cost, :transfer_in) do
      AuditLog.record(:warehouse_transfer, %{
        sku: sku,
        from: from_id,
        to: to_id,
        quantity: quantity,
        requested_by: user_id,
        timestamp: DateTime.utc_now()
      })

      {:ok, %{transferred: quantity, from: from_id, to: to_id}}
    else
      false -> {:error, :insufficient_stock}
      {:error, reason} -> {:error, reason}
    end
  end

end
```
