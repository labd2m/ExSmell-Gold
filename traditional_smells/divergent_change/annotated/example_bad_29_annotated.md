# Annotated Example — Divergent Change

## Metadata

- **Smell name:** Divergent Change
- **Expected smell location:** `WarehouseOperations` module (entire module)
- **Affected functions:** `receive_goods/2`, `pick_items/2`, `plan_replenishment/1`, `generate_stock_report/1`, `export_discrepancy_report/2`
- **Explanation:** `WarehouseOperations` combines inbound goods receiving, pick-list generation, replenishment planning, and stock/discrepancy reporting. These are distinct operational concerns — receiving rules may change with supplier contracts, picking logic with warehouse layout changes, and reporting formats with business intelligence needs — making this a Divergent Change.

---

```elixir
defmodule MyApp.WarehouseOperations do
  @moduledoc """
  Manages warehouse operations including goods receiving, order picking,
  inventory replenishment, and operational reporting.
  """

  alias MyApp.Repo
  alias MyApp.Schemas.{GoodsReceipt, PickList, PickListItem, StockLevel}
  import Ecto.Query

  # VALIDATION: SMELL START - Divergent Change
  # VALIDATION: This is a smell because the module combines four unrelated
  # warehouse concerns: inbound receiving, outbound picking, replenishment
  # planning, and reporting. Each has independent reasons to change, such
  # as new supplier protocols, layout-driven picking rules, reorder
  # strategies, or report formatting requirements.

  ## ── Goods Receiving ─────────────────────────────────────────────────────────

  @doc """
  Records receipt of goods from a supplier purchase order.
  Updates stock levels for each received SKU.
  """
  def receive_goods(purchase_order_id, line_items) do
    Repo.transaction(fn ->
      receipt =
        %GoodsReceipt{}
        |> GoodsReceipt.changeset(%{
          purchase_order_id: purchase_order_id,
          received_at: DateTime.utc_now(),
          status: :pending_putaway
        })
        |> Repo.insert!()

      Enum.each(line_items, fn %{sku: sku, quantity: qty, location: loc} ->
        upsert_stock(sku, qty, loc)

        %MyApp.Schemas.GoodsReceiptLine{}
        |> MyApp.Schemas.GoodsReceiptLine.changeset(%{
          goods_receipt_id: receipt.id,
          sku: sku,
          quantity: qty,
          location: loc
        })
        |> Repo.insert!()
      end)

      receipt
    end)
  end

  defp upsert_stock(sku, qty, location) do
    case Repo.get_by(StockLevel, sku: sku, location: location) do
      nil ->
        %StockLevel{}
        |> StockLevel.changeset(%{sku: sku, quantity: qty, location: location})
        |> Repo.insert!()

      existing ->
        existing
        |> StockLevel.changeset(%{quantity: existing.quantity + qty})
        |> Repo.update!()
    end
  end

  ## ── Order Picking ───────────────────────────────────────────────────────────

  @doc """
  Generates a pick list for the given order, selecting optimal warehouse locations.
  """
  def pick_items(%{id: order_id, items: items}) do
    Repo.transaction(fn ->
      pick_list =
        %PickList{}
        |> PickList.changeset(%{order_id: order_id, created_at: DateTime.utc_now(), status: :open})
        |> Repo.insert!()

      Enum.each(items, fn %{sku: sku, quantity: qty} ->
        location = best_pick_location(sku, qty)

        %PickListItem{}
        |> PickListItem.changeset(%{
          pick_list_id: pick_list.id,
          sku: sku,
          quantity: qty,
          location: location
        })
        |> Repo.insert!()

        from(s in StockLevel, where: s.sku == ^sku and s.location == ^location)
        |> Repo.update_all(inc: [reserved_quantity: qty])
      end)

      pick_list
    end)
  end

  defp best_pick_location(sku, _qty) do
    Repo.one(
      from s in StockLevel,
        where: s.sku == ^sku and s.quantity > s.reserved_quantity,
        order_by: [desc: s.quantity],
        limit: 1,
        select: s.location
    )
  end

  ## ── Replenishment Planning ───────────────────────────────────────────────────

  @doc """
  Evaluates current stock levels and returns a list of SKUs that need replenishment.
  """
  def plan_replenishment(reorder_threshold) do
    from(s in StockLevel,
      group_by: s.sku,
      having: sum(s.quantity) - sum(s.reserved_quantity) < ^reorder_threshold,
      select: %{
        sku: s.sku,
        available: sum(s.quantity) - sum(s.reserved_quantity),
        suggested_order: ^reorder_threshold * 3
      }
    )
    |> Repo.all()
  end

  ## ── Reporting ────────────────────────────────────────────────────────────────

  @doc """
  Generates a current snapshot of stock levels grouped by SKU.
  """
  def generate_stock_report(location \\ nil) do
    query =
      from s in StockLevel,
        group_by: s.sku,
        select: %{
          sku: s.sku,
          total_quantity: sum(s.quantity),
          reserved: sum(s.reserved_quantity),
          available: sum(s.quantity) - sum(s.reserved_quantity)
        }

    filtered = if location, do: from(s in query, where: s.location == ^location), else: query
    Repo.all(filtered)
  end

  @doc """
  Exports a discrepancy report comparing system stock to a physical count.
  Returns a CSV binary.
  """
  def export_discrepancy_report(physical_counts, as_of_date) do
    system_levels =
      Repo.all(from s in StockLevel, select: %{sku: s.sku, location: s.location, quantity: s.quantity})
      |> Map.new(fn %{sku: sku, location: loc} = row -> {"#{sku}:#{loc}", row} end)

    header = "sku,location,system_qty,physical_qty,discrepancy,as_of\n"

    body =
      Enum.map_join(physical_counts, "\n", fn %{sku: sku, location: loc, qty: phys} ->
        sys_qty = get_in(system_levels, ["#{sku}:#{loc}", :quantity]) || 0
        diff = phys - sys_qty
        "#{sku},#{loc},#{sys_qty},#{phys},#{diff},#{as_of_date}"
      end)

    header <> body
  end

  # VALIDATION: SMELL END
end
```
