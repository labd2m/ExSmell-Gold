# Annotated Example — Duplicated Code

## Metadata

- **Smell name:** Duplicated Code
- **Expected smell location:** `InventoryManager.reserve_stock/2` and `InventoryManager.can_fulfill?/2`
- **Affected functions:** `reserve_stock/2`, `can_fulfill?/2`
- **Short explanation:** Both functions independently iterate over requested items, look up current stock, account for already-reserved quantities, and compare against the requested amount. This availability-check logic is duplicated instead of being shared.

---

```elixir
defmodule InventoryManager do
  @moduledoc """
  Manages stock levels, reservations, and fulfillment checks for the warehouse system.
  """

  alias Inventory.{StockRecord, Reservation, Warehouse, AuditTrail}

  @reservation_ttl_minutes 30

  def reserve_stock(order_id, line_items) do
    # VALIDATION: SMELL START - Duplicated Code
    # VALIDATION: This is a smell because the per-item availability computation
    # (fetch record, subtract existing reservations, compare to requested qty)
    # is duplicated in full inside `can_fulfill?/2`. Changing the reservation
    # logic (e.g., adding safety-stock buffers) must be done in both functions.
    shortfalls =
      Enum.reduce(line_items, [], fn item, acc ->
        case StockRecord.fetch(item.sku) do
          {:ok, record} ->
            reserved = Reservation.total_reserved(item.sku)
            available = record.quantity_on_hand - reserved

            if available >= item.quantity do
              acc
            else
              [{item.sku, available, item.quantity} | acc]
            end

          {:error, :not_found} ->
            [{item.sku, 0, item.quantity} | acc]
        end
      end)
    # VALIDATION: SMELL END

    if Enum.empty?(shortfalls) do
      reservations =
        Enum.map(line_items, fn item ->
          %Reservation{
            id: Ecto.UUID.generate(),
            order_id: order_id,
            sku: item.sku,
            quantity: item.quantity,
            expires_at:
              DateTime.add(DateTime.utc_now(), @reservation_ttl_minutes * 60, :second),
            status: :active
          }
        end)

      Enum.each(reservations, &Reservation.persist/1)
      AuditTrail.log(:stock_reserved, order_id, line_items)
      {:ok, reservations}
    else
      {:error, {:insufficient_stock, shortfalls}}
    end
  end

  def can_fulfill?(warehouse_id, line_items) do
    with {:ok, _warehouse} <- Warehouse.fetch(warehouse_id) do
      # VALIDATION: SMELL START - Duplicated Code
      # VALIDATION: This is a smell because the availability check block here
      # duplicates the one in `reserve_stock/2`. Both compute the same available
      # quantity in the same way and accumulate the same shortfall tuples.
      shortfalls =
        Enum.reduce(line_items, [], fn item, acc ->
          case StockRecord.fetch(item.sku) do
            {:ok, record} ->
              reserved = Reservation.total_reserved(item.sku)
              available = record.quantity_on_hand - reserved

              if available >= item.quantity do
                acc
              else
                [{item.sku, available, item.quantity} | acc]
              end

            {:error, :not_found} ->
              [{item.sku, 0, item.quantity} | acc]
          end
        end)
      # VALIDATION: SMELL END

      if Enum.empty?(shortfalls) do
        {:ok, :fulfillable}
      else
        {:ok, {:partial, shortfalls}}
      end
    end
  end

  def release_reservation(order_id) do
    case Reservation.fetch_by_order(order_id) do
      {:ok, reservations} ->
        Enum.each(reservations, fn r ->
          Reservation.update(r, %{status: :released})
        end)

        AuditTrail.log(:stock_released, order_id)
        :ok

      {:error, :not_found} ->
        {:error, :reservation_not_found}
    end
  end

  def replenish(sku, quantity, supplier_ref) do
    with {:ok, record} <- StockRecord.fetch_or_create(sku) do
      updated_qty = record.quantity_on_hand + quantity

      StockRecord.update(record, %{
        quantity_on_hand: updated_qty,
        last_replenished_at: DateTime.utc_now(),
        supplier_ref: supplier_ref
      })

      AuditTrail.log(:stock_replenished, sku, %{quantity: quantity, supplier: supplier_ref})
      :ok
    end
  end
end
```
