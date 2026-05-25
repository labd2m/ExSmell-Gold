# Annotated Example — Large Module

- **Smell name:** Large Class (Large Module)
- **Expected smell location:** The entire `InventoryControl` module
- **Affected functions:** `receive_stock/2`, `transfer_stock/3`, `adjust_stock/3`, `reorder_check/1`, `generate_reorder_po/1`, `value_inventory/0`, `export_stock_report/1`, `audit_discrepancy/2`, `locate_product/1`
- **Short explanation:** `InventoryControl` conflates stock movement (receiving, transferring, adjusting), reorder automation (checking thresholds, generating purchase orders), financial valuation, reporting/export, audit/discrepancy tracking, and warehouse location lookups. These responsibilities span multiple bounded contexts and should be split into focused modules such as `Inventory.StockMovement`, `Inventory.Reorder`, `Inventory.Valuation`, and `Inventory.Audit`.

```elixir
# VALIDATION: SMELL START - Large Class (Large Module)
# VALIDATION: This is a smell because InventoryControl handles stock movements,
# reorder logic, financial valuation, CSV reporting, discrepancy auditing, and
# warehouse location queries inside one module — a clear violation of cohesion
# that results in an oversized module spanning multiple bounded contexts.
defmodule InventoryControl do
  @moduledoc """
  Manages stock levels, stock movements, reorder policies, inventory valuation,
  reporting exports, discrepancy audits, and warehouse location queries.
  """

  require Logger
  import Ecto.Query
  alias Inventory.Repo
  alias Inventory.Product
  alias Inventory.StockMovement
  alias Inventory.PurchaseOrder
  alias Inventory.WarehouseLocation

  @low_stock_multiplier 1.5

  # --- Stock receiving ---

  def receive_stock(product_id, quantity) when quantity > 0 do
    Repo.transaction(fn ->
      product = Repo.get!(Product, product_id)
      updated_qty = product.stock_quantity + quantity

      product
      |> Product.changeset(%{stock_quantity: updated_qty})
      |> Repo.update!()

      Repo.insert!(
        StockMovement.changeset(%StockMovement{}, %{
          product_id: product_id,
          type: :receipt,
          quantity: quantity,
          recorded_at: DateTime.utc_now()
        })
      )

      Logger.info("Received #{quantity} units of product #{product_id}")
      :ok
    end)
  end

  # --- Stock transfer between warehouses ---

  def transfer_stock(product_id, from_warehouse_id, to_warehouse_id, quantity) do
    Repo.transaction(fn ->
      source = Repo.get_by!(WarehouseLocation, product_id: product_id, warehouse_id: from_warehouse_id)
      dest   = Repo.get_by(WarehouseLocation, product_id: product_id, warehouse_id: to_warehouse_id)

      if source.quantity < quantity, do: Repo.rollback(:insufficient_stock)

      source |> WarehouseLocation.changeset(%{quantity: source.quantity - quantity}) |> Repo.update!()

      case dest do
        nil ->
          Repo.insert!(
            WarehouseLocation.changeset(%WarehouseLocation{}, %{
              product_id: product_id,
              warehouse_id: to_warehouse_id,
              quantity: quantity
            })
          )
        existing ->
          existing
          |> WarehouseLocation.changeset(%{quantity: existing.quantity + quantity})
          |> Repo.update!()
      end

      Repo.insert!(
        StockMovement.changeset(%StockMovement{}, %{
          product_id: product_id,
          type: :transfer,
          quantity: quantity,
          from_warehouse_id: from_warehouse_id,
          to_warehouse_id: to_warehouse_id,
          recorded_at: DateTime.utc_now()
        })
      )
    end)
  end

  # --- Manual stock adjustment ---

  def adjust_stock(product_id, delta, reason) do
    product = Repo.get!(Product, product_id)
    new_qty = max(0, product.stock_quantity + delta)

    product
    |> Product.changeset(%{stock_quantity: new_qty})
    |> Repo.update()

    Repo.insert!(
      StockMovement.changeset(%StockMovement{}, %{
        product_id: product_id,
        type: :adjustment,
        quantity: delta,
        notes: reason,
        recorded_at: DateTime.utc_now()
      })
    )
  end

  # --- Reorder management ---

  def reorder_check(product_id) do
    product = Repo.get!(Product, product_id)
    threshold = Float.round(product.avg_monthly_sales * @low_stock_multiplier, 0)

    if product.stock_quantity <= threshold do
      {:reorder_needed, product}
    else
      :ok
    end
  end

  def generate_reorder_po(product) do
    reorder_qty = round(product.avg_monthly_sales * 3)

    attrs = %{
      product_id: product.id,
      quantity: reorder_qty,
      supplier_id: product.preferred_supplier_id,
      status: :draft,
      created_at: DateTime.utc_now()
    }

    case Repo.insert(PurchaseOrder.changeset(%PurchaseOrder{}, attrs)) do
      {:ok, po} ->
        Logger.info("PO #{po.id} created for product #{product.id}, qty #{reorder_qty}")
        {:ok, po}
      {:error, cs} ->
        {:error, cs}
    end
  end

  # --- Financial valuation ---

  def value_inventory do
    from(p in Product, select: {p.id, p.sku, p.stock_quantity, p.unit_cost})
    |> Repo.all()
    |> Enum.map(fn {id, sku, qty, cost} ->
      %{product_id: id, sku: sku, quantity: qty, unit_cost: cost, total_value: Decimal.mult(cost, qty)}
    end)
    |> then(fn rows ->
      total = Enum.reduce(rows, Decimal.new("0"), fn r, acc -> Decimal.add(acc, r.total_value) end)
      %{lines: rows, total_inventory_value: total}
    end)
  end

  # --- CSV reporting ---

  def export_stock_report(path) do
    rows = value_inventory().lines

    header = "product_id,sku,quantity,unit_cost,total_value\n"

    lines =
      Enum.map(rows, fn r ->
        "#{r.product_id},#{r.sku},#{r.quantity},#{r.unit_cost},#{r.total_value}\n"
      end)

    File.write!(path, [header | lines])
    Logger.info("Stock report exported to #{path}")
    :ok
  end

  # --- Discrepancy audit ---

  def audit_discrepancy(product_id, physical_count) do
    product = Repo.get!(Product, product_id)
    delta = physical_count - product.stock_quantity

    if delta != 0 do
      Logger.warning(
        "Discrepancy for product #{product_id}: system=#{product.stock_quantity}, physical=#{physical_count}, delta=#{delta}"
      )

      adjust_stock(product_id, delta, "physical count audit")
      {:discrepancy, %{product_id: product_id, delta: delta}}
    else
      :ok
    end
  end

  # --- Warehouse location lookup ---

  def locate_product(product_id) do
    from(wl in WarehouseLocation,
      where: wl.product_id == ^product_id and wl.quantity > 0,
      select: %{warehouse_id: wl.warehouse_id, quantity: wl.quantity}
    )
    |> Repo.all()
  end
end
# VALIDATION: SMELL END
```
