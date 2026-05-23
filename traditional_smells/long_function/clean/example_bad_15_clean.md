```elixir
defmodule Inventory.ReorderAgent do
  @moduledoc """
  Evaluates current stock levels and automatically generates purchase orders
  for SKUs that have fallen below their configured reorder points.
  """

  alias Inventory.{StockItem, PurchaseOrder, POLine, Repo}
  alias Notifications.Dispatcher
  require Logger

  @default_lead_time_days 7
  @safety_stock_factor 1.3
  @purchasing_manager_user_id Application.compile_env(:inventory, :purchasing_manager_id, "system")

  def evaluate_and_reorder(warehouse_id) do
    Logger.info("Running reorder evaluation for warehouse=#{warehouse_id}")

    # --- Load all active stock items for warehouse ---
    stock_items =
      StockItem
      |> StockItem.for_warehouse(warehouse_id)
      |> StockItem.active()
      |> Repo.all()
      |> Repo.preload(:supplier)

    # --- Filter items below reorder point ---
    below_threshold =
      Enum.filter(stock_items, fn item ->
        available = item.on_hand - item.reserved
        available <= item.reorder_point
      end)

    if Enum.empty?(below_threshold) do
      Logger.info("No items below reorder point for warehouse #{warehouse_id}")
      {:ok, 0}
    else
      Logger.info("#{length(below_threshold)} SKU(s) require reorder in warehouse #{warehouse_id}")

      # --- Load open purchase orders to avoid duplicate reorders ---
      open_po_skus =
        PurchaseOrder
        |> PurchaseOrder.open()
        |> PurchaseOrder.for_warehouse(warehouse_id)
        |> Repo.all()
        |> Repo.preload(:lines)
        |> Enum.flat_map(fn po -> Enum.map(po.lines, & &1.sku) end)
        |> MapSet.new()

      # --- Filter out SKUs already on open POs ---
      actionable_items = Enum.reject(below_threshold, fn item -> MapSet.member?(open_po_skus, item.sku) end)

      if Enum.empty?(actionable_items) do
        Logger.info("All below-threshold SKUs already have open POs, nothing to do")
        {:ok, 0}
      else
        # --- Group by supplier for PO consolidation ---
        by_supplier = Enum.group_by(actionable_items, fn item -> item.supplier_id end)

        created_pos =
          Enum.map(by_supplier, fn {supplier_id, items} ->
            # --- Build PO lines with reorder quantities ---
            po_lines =
              Enum.map(items, fn item ->
                lead_time = item.supplier.lead_time_days || @default_lead_time_days
                daily_demand = item.avg_daily_demand || 1.0
                needed = ceil(daily_demand * lead_time * @safety_stock_factor)
                qty_to_order = max(needed, item.min_order_qty || 1)

                %{
                  sku: item.sku,
                  description: item.description,
                  qty_ordered: qty_to_order,
                  unit_cost: item.last_purchase_price || 0.0,
                  reorder_point: item.reorder_point
                }
              end)

            total_value =
              Enum.reduce(po_lines, 0.0, fn line, acc ->
                acc + line.qty_ordered * line.unit_cost
              end)

            # --- Create PO ---
            po_attrs = %{
              warehouse_id: warehouse_id,
              supplier_id: supplier_id,
              status: :draft,
              total_value: total_value,
              auto_generated: true,
              requested_at: DateTime.utc_now()
            }

            {:ok, po} = Repo.insert(PurchaseOrder.changeset(%PurchaseOrder{}, po_attrs))

            Enum.each(po_lines, fn line_attrs ->
              Repo.insert!(POLine.changeset(%POLine{}, Map.put(line_attrs, :purchase_order_id, po.id)))
            end)

            Logger.info("Auto-generated PO #{po.id} for supplier #{supplier_id} with #{length(po_lines)} line(s)")
            po
          end)

        # --- Notify purchasing manager ---
        Dispatcher.dispatch(@purchasing_manager_user_id, %{
          type: "reorder_pos_generated",
          payload: %{
            warehouse_id: warehouse_id,
            po_count: length(created_pos),
            po_ids: Enum.map(created_pos, & &1.id)
          }
        })

        {:ok, length(created_pos)}
      end
    end
  end
end
```
