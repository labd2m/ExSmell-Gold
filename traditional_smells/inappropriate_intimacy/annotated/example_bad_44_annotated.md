# Annotated Example — Code Smell

- **Smell name:** Inappropriate Intimacy
- **Expected smell location:** `Inventory.StockManager.replenish/2`
- **Affected function(s):** `replenish/2`, `compute_reorder_quantity/2`
- **Short explanation:** `StockManager` directly reads internal fields of `Product` (`product.reorder_point`, `product.reorder_qty`, `product.lead_time_days`, `product.discontinued`) and `Warehouse` (`warehouse.accepts_inbound`, `warehouse.capacity_units`, `warehouse.current_units`) to make replenishment decisions. This business logic should be delegated to the `Product` and `Warehouse` modules rather than reconstructed here.

```elixir
defmodule Inventory.StockManager do
  @moduledoc """
  Evaluates stock levels and triggers purchase orders for items that
  fall below their reorder thresholds across all active warehouses.
  """

  require Logger

  alias Inventory.{Product, Warehouse, StockLevel, PurchaseOrder}
  alias Inventory.Suppliers
  alias Repo

  @safety_stock_multiplier 1.2

  def run_replenishment_check(warehouse_id) do
    with {:ok, warehouse} <- Warehouse.fetch(warehouse_id),
         {:ok, stock_levels} <- StockLevel.list_for_warehouse(warehouse_id) do
      stock_levels
      |> Enum.map(fn sl -> maybe_replenish(sl, warehouse) end)
      |> Enum.filter(fn
        {:ok, _} -> true
        _ -> false
      end)
      |> then(fn results ->
        Logger.info("Replenishment check done: #{length(results)} orders created")
        {:ok, length(results)}
      end)
    end
  end

  def replenish(stock_level_id, override_qty \\ nil) do
    with {:ok, sl} <- StockLevel.fetch(stock_level_id),
         {:ok, product} <- Product.fetch(sl.product_id),
         {:ok, warehouse} <- Warehouse.fetch(sl.warehouse_id) do
      do_replenish(sl, product, warehouse, override_qty)
    end
  end

  # VALIDATION: SMELL START - Inappropriate Intimacy
  # VALIDATION: This is a smell because do_replenish/4 and compute_reorder_quantity/2
  # VALIDATION: directly access internal fields of Product (discontinued, reorder_point,
  # VALIDATION: lead_time_days, reorder_qty, supplier_id, sku) and Warehouse
  # VALIDATION: (accepts_inbound, capacity_units, current_units) to drive business
  # VALIDATION: logic that belongs inside Product and Warehouse themselves.
  defp do_replenish(sl, product, warehouse, override_qty) do
    cond do
      product.discontinued ->
        Logger.info("Skipping replenishment for discontinued SKU #{product.sku}")
        {:ok, :skipped_discontinued}

      not warehouse.accepts_inbound ->
        Logger.warning("Warehouse #{warehouse.id} is not accepting inbound; skipping")
        {:ok, :skipped_warehouse_closed}

      sl.quantity_on_hand > product.reorder_point ->
        {:ok, :above_threshold}

      true ->
        qty = override_qty || compute_reorder_quantity(product, warehouse)

        free_capacity = warehouse.capacity_units - warehouse.current_units

        if qty > free_capacity do
          Logger.warning(
            "Warehouse #{warehouse.id} lacks capacity for full reorder; capping at #{free_capacity}"
          )
        end

        final_qty = min(qty, free_capacity)

        if final_qty <= 0 do
          Logger.warning("No capacity to replenish SKU #{product.sku} at warehouse #{warehouse.id}")
          {:ok, :skipped_no_capacity}
        else
          create_purchase_order(product, warehouse, sl, final_qty)
        end
    end
  end

  defp compute_reorder_quantity(product, warehouse) do
    daily_usage = estimate_daily_usage(product.id, warehouse.id)

    demand_during_lead_time = daily_usage * product.lead_time_days
    safety_stock = demand_during_lead_time * @safety_stock_multiplier

    max(product.reorder_qty, round(demand_during_lead_time + safety_stock))
  end
  # VALIDATION: SMELL END

  defp maybe_replenish(%StockLevel{} = sl, warehouse) do
    with {:ok, product} <- Product.fetch(sl.product_id) do
      if not product.discontinued and sl.quantity_on_hand <= product.reorder_point do
        replenish(sl.id)
      else
        {:ok, :no_action}
      end
    end
  end

  defp create_purchase_order(product, warehouse, sl, quantity) do
    supplier = Suppliers.primary_for_product(product.id)

    order = %PurchaseOrder{
      product_id: product.id,
      warehouse_id: warehouse.id,
      stock_level_id: sl.id,
      supplier_id: supplier.id,
      quantity: quantity,
      unit_cost_cents: supplier.unit_cost_cents,
      status: :pending,
      expected_delivery_days: product.lead_time_days,
      created_at: DateTime.utc_now()
    }

    case Repo.insert(order) do
      {:ok, po} ->
        Logger.info("PO #{po.id} created: #{quantity} units of SKU #{product.sku}")
        {:ok, po}

      {:error, changeset} ->
        Logger.error("Failed to create PO: #{inspect(changeset.errors)}")
        {:error, :creation_failed}
    end
  end

  defp estimate_daily_usage(product_id, warehouse_id) do
    StockLevel.average_daily_sales(product_id, warehouse_id) || 1
  end
end
```
