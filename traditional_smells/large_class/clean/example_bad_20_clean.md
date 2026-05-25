```elixir
defmodule InventoryManager do
  @moduledoc """
  Manages all inventory operations including stock, reservations, and valuation.
  """

  require Logger
  import Ecto.Query

  alias MyApp.Repo
  alias MyApp.Inventory.{StockLevel, Reservation, ReplenishmentOrder, StockMovement, PurchaseLot}
  alias MyApp.Procurement.PurchaseOrder

  @low_stock_threshold 20
  @reorder_quantity 100
  @valuation_method :fifo


  def adjust_stock(sku, warehouse_id, delta, reason) do
    level = get_or_create_stock_level(sku, warehouse_id)
    new_qty = level.quantity + delta

    if new_qty < 0 do
      {:error, :insufficient_stock}
    else
      with {:ok, updated} <-
             level
             |> StockLevel.changeset(%{quantity: new_qty})
             |> Repo.update(),
           {:ok, _} <- record_movement(sku, warehouse_id, delta, reason) do
        maybe_trigger_replenishment(updated)
        {:ok, updated}
      end
    end
  end

  def get_stock(sku, warehouse_id) do
    Repo.get_by(StockLevel, sku: sku, warehouse_id: warehouse_id)
    |> case do
      nil -> {:ok, 0}
      %StockLevel{quantity: q} -> {:ok, q}
    end
  end

  defp get_or_create_stock_level(sku, warehouse_id) do
    case Repo.get_by(StockLevel, sku: sku, warehouse_id: warehouse_id) do
      nil ->
        {:ok, sl} = Repo.insert(%StockLevel{sku: sku, warehouse_id: warehouse_id, quantity: 0})
        sl

      sl ->
        sl
    end
  end

  defp record_movement(sku, warehouse_id, delta, reason) do
    Repo.insert(%StockMovement{
      sku: sku,
      warehouse_id: warehouse_id,
      delta: delta,
      reason: reason,
      occurred_at: DateTime.utc_now()
    })
  end


  def reserve(sku, warehouse_id, quantity, reference_id) do
    with {:ok, available} <- get_available(sku, warehouse_id),
         true <- available >= quantity || {:error, :insufficient_available} do
      Repo.insert(%Reservation{
        sku: sku,
        warehouse_id: warehouse_id,
        quantity: quantity,
        reference_id: reference_id,
        reserved_at: DateTime.utc_now(),
        expires_at: DateTime.add(DateTime.utc_now(), 2 * 3600, :second)
      })
    end
  end

  def release_reservation(reference_id) do
    case Repo.get_by(Reservation, reference_id: reference_id) do
      nil -> {:error, :not_found}
      res -> Repo.delete(res)
    end
  end

  defp get_available(sku, warehouse_id) do
    {:ok, on_hand} = get_stock(sku, warehouse_id)
    reserved = total_reserved(sku, warehouse_id)
    {:ok, on_hand - reserved}
  end

  defp total_reserved(sku, warehouse_id) do
    now = DateTime.utc_now()

    Repo.one(
      from r in Reservation,
        where:
          r.sku == ^sku and r.warehouse_id == ^warehouse_id and
            r.expires_at > ^now,
        select: coalesce(sum(r.quantity), 0)
    )
  end


  defp maybe_trigger_replenishment(%StockLevel{quantity: q, sku: sku})
       when q <= @low_stock_threshold do
    unless pending_replenishment_exists?(sku) do
      Logger.info("Low stock alert for SKU #{sku}: #{q} units. Triggering reorder.")
      create_replenishment_order(sku, @reorder_quantity)
    end
  end

  defp maybe_trigger_replenishment(_), do: :ok

  defp pending_replenishment_exists?(sku) do
    Repo.exists?(from r in ReplenishmentOrder, where: r.sku == ^sku and r.status == :pending)
  end

  defp create_replenishment_order(sku, quantity) do
    %ReplenishmentOrder{
      sku: sku,
      quantity: quantity,
      status: :pending,
      created_at: DateTime.utc_now()
    }
    |> Repo.insert()
    |> case do
      {:ok, order} ->
        Logger.info("Replenishment order #{order.id} created for SKU #{sku}")
        {:ok, order}

      {:error, cs} ->
        Logger.error("Failed to create replenishment for #{sku}: #{inspect(cs.errors)}")
        {:error, cs}
    end
  end


  def calculate_valuation(sku) do
    lots = fetch_lots_ordered(sku, @valuation_method)
    {:ok, stock_qty} = get_stock(sku, :all_warehouses)

    {value, _remaining} =
      Enum.reduce_while(lots, {Decimal.new(0), stock_qty}, fn lot, {acc_val, remaining} ->
        if remaining <= 0 do
          {:halt, {acc_val, 0}}
        else
          units = min(lot.quantity, remaining)
          {:cont, {Decimal.add(acc_val, Decimal.mult(lot.unit_cost, units)), remaining - units}}
        end
      end)

    {:ok, value}
  end

  defp fetch_lots_ordered(sku, :fifo) do
    Repo.all(from l in PurchaseLot, where: l.sku == ^sku, order_by: [asc: l.received_at])
  end

  defp fetch_lots_ordered(sku, :lifo) do
    Repo.all(from l in PurchaseLot, where: l.sku == ^sku, order_by: [desc: l.received_at])
  end


  def stock_summary_report(warehouse_id) do
    Repo.all(
      from sl in StockLevel,
        where: sl.warehouse_id == ^warehouse_id,
        select: %{
          sku: sl.sku,
          quantity: sl.quantity,
          updated_at: sl.updated_at
        }
    )
  end

  def movement_report(sku, from_dt, to_dt) do
    Repo.all(
      from m in StockMovement,
        where:
          m.sku == ^sku and
            m.occurred_at >= ^from_dt and
            m.occurred_at <= ^to_dt,
        order_by: [asc: m.occurred_at]
    )
  end

  def low_stock_report(warehouse_id) do
    Repo.all(
      from sl in StockLevel,
        where: sl.warehouse_id == ^warehouse_id and sl.quantity <= @low_stock_threshold,
        order_by: [asc: sl.quantity]
    )
  end
end
```
