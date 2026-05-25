## Metadata

- **Smell name:** Speculative Generality
- **Expected smell location:** Function `compute_reorder_quantity/2` in `Inventory.ReplenishmentEngine`
- **Affected function(s):** `compute_reorder_quantity/2`
- **Explanation:** The function speculatively destructures `storage_class` from the item struct, anticipating that different storage classes (`:refrigerated`, `:hazmat`, `:bulk`, `:standard`) would require different reorder quantity calculations — for example, higher safety stock for perishables or smaller batch sizes for hazardous materials. In practice, the `case` block contains only a single catch-all clause that applies the same demand-driven formula for every item regardless of storage class. The variable `class` is extracted but never branched on.

---

```elixir
defmodule Inventory.ReplenishmentEngine do
  @moduledoc """
  Evaluates warehouse stock levels and emits purchase orders when item
  quantities fall below their configured reorder points.
  """

  alias Inventory.{Item, WarehouseStock, PurchaseOrder, Supplier}

  @safety_stock_factor    1.25
  @lead_time_days_default 7
  @max_order_quantity     10_000
  @min_order_quantity     1

  def run(warehouse_id) do
    warehouse_id
    |> WarehouseStock.list_below_reorder_point()
    |> Enum.map(&evaluate_item(&1, warehouse_id))
    |> Enum.reject(&match?({:skip, _}, &1))
    |> Enum.map(fn {:ok, order} -> order end)
  end

  def evaluate_item(%Item{} = item, warehouse_id) do
    stock = WarehouseStock.get(item.id, warehouse_id)

    cond do
      stock.quantity_on_hand >= stock.reorder_point ->
        {:skip, :sufficient_stock}

      stock.quantity_on_order > 0 ->
        {:skip, :order_already_in_progress}

      true ->
        create_replenishment_order(item, stock)
    end
  end

  def create_replenishment_order(%Item{} = item, stock) do
    quantity = compute_reorder_quantity(item, stock)
    supplier = Supplier.primary_for_item(item.id)

    order = %PurchaseOrder{
      item_id:      item.id,
      supplier_id:  supplier.id,
      quantity:     quantity,
      unit_cost:    supplier.unit_cost,
      expected_by:  Date.add(Date.utc_today(), supplier.lead_time_days || @lead_time_days_default),
      status:       :pending,
      created_at:   DateTime.utc_now()
    }

    case PurchaseOrder.insert(order) do
      {:ok, _} = ok -> ok
      error         -> error
    end
  end

  # VALIDATION: SMELL START - Speculative Generality
  # VALIDATION: This is a smell because the function speculatively destructures
  # `storage_class` from the item struct, anticipating that different storage
  # classes (e.g., `:refrigerated`, `:hazmat`, `:bulk`) would require different
  # reorder quantity strategies — such as higher safety stock multipliers for
  # perishables or smaller batch sizes for hazardous goods. In practice, the
  # `case` block contains only a single catch-all clause applying the same
  # demand-and-lead-time formula to every item. The variable `class` is bound
  # but never used in any real branch.
  def compute_reorder_quantity(%{storage_class: class} = item, stock) do
    base =
      case class do
        _ ->
          demand  = stock.average_daily_demand
          lead    = item.lead_time_days || stock.lead_time_days || @lead_time_days_default
          safety  = demand * lead * @safety_stock_factor
          reorder = demand * lead + safety
          ceil(reorder)
      end

    base
    |> max(@min_order_quantity)
    |> min(@max_order_quantity)
  end
  # VALIDATION: SMELL END

  def reorder_status(warehouse_id) do
    items_below  = WarehouseStock.count_below_reorder_point(warehouse_id)
    pending_pos  = PurchaseOrder.count_pending(warehouse_id)

    %{
      warehouse_id:             warehouse_id,
      items_needing_reorder:    items_below,
      pending_purchase_orders:  pending_pos,
      checked_at:               DateTime.utc_now()
    }
  end

  def acknowledge_receipt(%PurchaseOrder{id: po_id}, received_quantity) do
    with {:ok, po}    <- PurchaseOrder.fetch(po_id),
         :ok          <- PurchaseOrder.mark_received(po, received_quantity),
         {:ok, stock} <- WarehouseStock.get_for_po(po) do
      WarehouseStock.increment(stock, received_quantity)
    end
  end

  def overdue_orders(warehouse_id) do
    today = Date.utc_today()

    warehouse_id
    |> PurchaseOrder.list_pending()
    |> Enum.filter(&(Date.compare(&1.expected_by, today) == :lt))
  end

  defp format_quantity(n) when n >= 1_000, do: "#{div(n, 1_000)}k"
  defp format_quantity(n), do: to_string(n)
end
```
