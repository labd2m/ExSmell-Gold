# Annotated Example — Bad Code

- **Smell name:** Complex extractions in clauses
- **Expected smell location:** `adjust_stock/2` function, multi-clause heads
- **Affected function(s):** `adjust_stock/2`
- **Short explanation:** Each clause head extracts `sku`, `quantity`, `warehouse_id`, `product_name`, `reorder_point`, and `unit_cost` from `%StockRecord{}`. Only `quantity` drives the guard conditions. `warehouse_id`, `product_name`, `reorder_point`, and `unit_cost` — and even `sku` — serve only the function body. Every clause carries the full destructuring, making it hard to see that quantity alone governs dispatch.

```elixir
defmodule Inventory.StockAdjuster do
  @moduledoc """
  Handles stock adjustments, reorder triggers, and write-offs for
  warehouse inventory management.
  """

  alias Inventory.{StockRecord, PurchaseOrder, WriteOffRecord}
  alias Inventory.{WarehouseLog, AlertService, CostLedger}

  @critical_stock_level 10
  @low_stock_level 50

  # VALIDATION: SMELL START - Complex extractions in clauses
  # VALIDATION: This is a smell because `warehouse_id`, `product_name`,
  # `reorder_point`, `unit_cost`, and `sku` are all extracted in every clause
  # head even though none of them participate in the guard conditions. Only
  # `quantity` (compared against thresholds in guards) determines which clause
  # runs. All other bindings are used only in the body, and their presence in
  # the clause heads creates confusion about what actually drives dispatch.

  def adjust_stock(
        %StockRecord{
          sku: sku,
          quantity: quantity,
          warehouse_id: warehouse_id,
          product_name: product_name,
          reorder_point: reorder_point,
          unit_cost: unit_cost
        },
        delta
      )
      when quantity + delta <= 0 do
    write_off_qty = max(quantity, 0)
    total_write_off = Float.round(write_off_qty * unit_cost, 2)

    WriteOffRecord.create(%{
      sku: sku,
      warehouse_id: warehouse_id,
      product_name: product_name,
      qty: write_off_qty,
      cost: total_write_off,
      reason: :stock_depletion
    })

    CostLedger.debit(warehouse_id, total_write_off, :write_off)
    WarehouseLog.record(warehouse_id, sku, :depleted, 0)
    AlertService.send_critical(warehouse_id, product_name, sku, :out_of_stock)
    {:ok, :depleted, 0}
  end

  def adjust_stock(
        %StockRecord{
          sku: sku,
          quantity: quantity,
          warehouse_id: warehouse_id,
          product_name: product_name,
          reorder_point: reorder_point,
          unit_cost: unit_cost
        },
        delta
      )
      when quantity + delta <= @critical_stock_level do
    new_qty = quantity + delta
    _ = unit_cost

    PurchaseOrder.raise_urgent(%{
      sku: sku,
      warehouse_id: warehouse_id,
      product_name: product_name,
      qty_on_hand: new_qty,
      reorder_point: reorder_point
    })

    WarehouseLog.record(warehouse_id, sku, :critical, new_qty)
    AlertService.send_critical(warehouse_id, product_name, sku, :critical_stock)
    {:ok, :critical, new_qty}
  end

  def adjust_stock(
        %StockRecord{
          sku: sku,
          quantity: quantity,
          warehouse_id: warehouse_id,
          product_name: product_name,
          reorder_point: reorder_point,
          unit_cost: _unit_cost
        },
        delta
      )
      when quantity + delta <= @low_stock_level do
    new_qty = quantity + delta

    if new_qty <= reorder_point do
      PurchaseOrder.raise_standard(%{
        sku: sku,
        warehouse_id: warehouse_id,
        product_name: product_name,
        qty_on_hand: new_qty,
        reorder_point: reorder_point
      })
    end

    WarehouseLog.record(warehouse_id, sku, :low, new_qty)
    AlertService.send_warning(warehouse_id, product_name, sku, :low_stock)
    {:ok, :low, new_qty}
  end

  def adjust_stock(
        %StockRecord{
          sku: sku,
          quantity: quantity,
          warehouse_id: warehouse_id,
          product_name: _product_name,
          reorder_point: _reorder_point,
          unit_cost: _unit_cost
        },
        delta
      ) do
    new_qty = quantity + delta
    WarehouseLog.record(warehouse_id, sku, :normal, new_qty)
    {:ok, :normal, new_qty}
  end

  # VALIDATION: SMELL END
end
```
