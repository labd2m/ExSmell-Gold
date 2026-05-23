```elixir
defmodule Inventory.StockManager do
  @moduledoc """
  Manages stock levels in response to purchase order receipts,
  adjustments, and reservations.
  """

  alias Inventory.{StockItem, PurchaseOrder, POLine, StockEvent, Repo}
  alias Integrations.SupplierPortal
  require Logger

  @low_stock_multiplier 1.5

  def receive_purchase_order(po_id, received_lines) when is_list(received_lines) do
    Logger.info("Receiving purchase order po_id=#{po_id}")

    case Repo.get(PurchaseOrder, po_id) |> Repo.preload(:lines) do
      nil ->
        {:error, :purchase_order_not_found}

      %PurchaseOrder{status: status} when status not in [:approved, :partially_received] ->
        Logger.warning("PO #{po_id} cannot be received in status #{status}")
        {:error, {:invalid_po_status, status}}

      %PurchaseOrder{} = po ->
        # --- Validate received lines against PO ---
        po_line_index = Map.new(po.lines, &{&1.sku, &1})

        invalid_skus =
          received_lines
          |> Enum.map(& &1.sku)
          |> Enum.reject(&Map.has_key?(po_line_index, &1))

        if invalid_skus != [] do
          {:error, {:unknown_skus, invalid_skus}}
        else
          # --- Update stock for each received line ---
          stock_updates =
            Enum.map(received_lines, fn line ->
              po_line = Map.fetch!(po_line_index, line.sku)
              qty_received = min(line.qty_received, po_line.qty_ordered - po_line.qty_received)

              stock_item =
                case Repo.get_by(StockItem, sku: line.sku) do
                  nil ->
                    %StockItem{}
                    |> StockItem.changeset(%{
                      sku: line.sku,
                      on_hand: qty_received,
                      reserved: 0,
                      reorder_point: po_line.reorder_point || 10
                    })
                    |> Repo.insert!()

                  existing ->
                    existing
                    |> StockItem.changeset(%{on_hand: existing.on_hand + qty_received})
                    |> Repo.update!()
                end

              # --- Record stock event ---
              Repo.insert!(StockEvent.changeset(%StockEvent{}, %{
                sku: line.sku,
                event_type: :receipt,
                quantity: qty_received,
                reference_id: po_id,
                occurred_at: DateTime.utc_now()
              }))

              # --- Update PO line qty received ---
              po_line
              |> POLine.changeset(%{qty_received: po_line.qty_received + qty_received})
              |> Repo.update!()

              {line.sku, stock_item, qty_received}
            end)

          # --- Check for low stock levels and emit alerts ---
          Enum.each(stock_updates, fn {sku, stock_item, _qty} ->
            if stock_item.on_hand <= stock_item.reorder_point * @low_stock_multiplier do
              Logger.warning("Low stock alert: SKU #{sku} on_hand=#{stock_item.on_hand}, reorder_point=#{stock_item.reorder_point}")
              # Would trigger a reorder notification here
            end
          end)

          # --- Determine if PO is fully received ---
          updated_po_lines = Repo.preload(po, :lines, force: true).lines

          all_received =
            Enum.all?(updated_po_lines, fn l ->
              l.qty_received >= l.qty_ordered
            end)

          new_po_status = if all_received, do: :received, else: :partially_received

          po
          |> PurchaseOrder.changeset(%{
            status: new_po_status,
            received_at: (if all_received, do: DateTime.utc_now(), else: nil)
          })
          |> Repo.update!()

          # --- Acknowledge receipt with supplier ---
          case SupplierPortal.acknowledge_receipt(po.supplier_id, po_id, received_lines) do
            {:ok, _} ->
              Logger.info("Supplier #{po.supplier_id} acknowledged receipt for PO #{po_id}")

            {:error, reason} ->
              Logger.warning("Supplier acknowledgement failed for PO #{po_id}: #{inspect(reason)}")
          end

          Logger.info("PO #{po_id} received, new status: #{new_po_status}")
          {:ok, %{po_id: po_id, status: new_po_status, updates: stock_updates}}
        end
    end
  end

  def reserve(sku, qty) when qty > 0 do
    case Repo.get_by(StockItem, sku: sku) do
      nil -> {:error, :sku_not_found}
      item when item.on_hand - item.reserved < qty -> {:error, :insufficient_stock}
      item ->
        item |> StockItem.changeset(%{reserved: item.reserved + qty}) |> Repo.update()
    end
  end
end
```
