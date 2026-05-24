# Code Smell Example – Annotated

## Metadata

- **Smell name:** Inappropriate Intimacy
- **Expected smell location:** `StockAllocator.reserve/3` function
- **Affected function(s):** `StockAllocator.reserve/3`
- **Short explanation:** `StockAllocator.reserve/3` fetches a `Warehouse` struct and a `Product` struct and directly reads their internal fields (`.storage_zones`, `.hazmat_licensed`, `.requires_cold_chain`, `.storage_class`) to make allocation decisions. This logic couples the allocator tightly to the internal data model of both `Warehouse` and `Product`, which should instead expose this information through dedicated query functions.

---

```elixir
defmodule MyApp.Inventory.StockAllocator do
  @moduledoc """
  Allocates stock from available warehouses when orders are placed.
  Respects warehouse capabilities and product storage requirements.
  """

  alias MyApp.Inventory.{Warehouse, Product, Reservation}
  alias MyApp.Inventory.LedgerWriter

  @reservation_ttl_minutes 30

  def reserve(order_id, product_id, quantity) do
    with {:ok, product}   <- Product.fetch(product_id),
         {:ok, warehouses} <- Warehouse.list_available() do

      # VALIDATION: SMELL START - Inappropriate Intimacy
      # VALIDATION: This is a smell because reserve/3 directly reads .requires_cold_chain
      # and .storage_class from the Product struct, and .storage_zones and .hazmat_licensed
      # from each Warehouse struct, instead of asking those modules through dedicated
      # capability-query functions whether they are compatible.
      needs_cold      = product.requires_cold_chain
      storage_class   = product.storage_class

      suitable =
        Enum.filter(warehouses, fn wh ->
          has_cold      = :cold_storage in wh.storage_zones
          has_hazmat    = wh.hazmat_licensed
          class_ok      = storage_class in wh.storage_zones

          (not needs_cold or has_cold) and
            (storage_class != :hazmat or has_hazmat) and
            class_ok
        end)
      # VALIDATION: SMELL END

      case choose_warehouse(suitable, quantity) do
        nil ->
          {:error, :no_suitable_warehouse}

        warehouse ->
          reservation = build_reservation(order_id, product_id, warehouse.id, quantity)
          LedgerWriter.write_reservation(reservation)
          {:ok, reservation}
      end
    end
  end

  def confirm(reservation_id) do
    case Reservation.fetch(reservation_id) do
      nil -> {:error, :not_found}
      res when res.status == :expired -> {:error, :reservation_expired}
      res ->
        LedgerWriter.write_confirmation(res)
        {:ok, %{res | status: :confirmed}}
    end
  end

  def release(reservation_id) do
    case Reservation.fetch(reservation_id) do
      nil -> {:error, :not_found}
      res ->
        LedgerWriter.write_release(res)
        {:ok, %{res | status: :released}}
    end
  end

  def expire_stale do
    cutoff = DateTime.utc_now() |> DateTime.add(-@reservation_ttl_minutes * 60, :second)
    :ets.tab2list(:reservations)
    |> Enum.filter(fn {_, r} ->
      r.status == :pending and DateTime.compare(r.created_at, cutoff) == :lt
    end)
    |> Enum.each(fn {id, _} ->
      release(id)
    end)
  end

  # --- Private helpers ---

  defp choose_warehouse([], _quantity), do: nil

  defp choose_warehouse(warehouses, quantity) do
    warehouses
    |> Enum.filter(&has_stock?(&1, quantity))
    |> Enum.min_by(& &1.distance_km, fn -> nil end)
  end

  defp has_stock?(warehouse, quantity) do
    available = Warehouse.available_stock(warehouse.id)
    available >= quantity
  end

  defp build_reservation(order_id, product_id, warehouse_id, quantity) do
    %{
      id:           generate_id(),
      order_id:     order_id,
      product_id:   product_id,
      warehouse_id: warehouse_id,
      quantity:     quantity,
      status:       :pending,
      created_at:   DateTime.utc_now(),
      expires_at:   DateTime.utc_now() |> DateTime.add(@reservation_ttl_minutes * 60, :second)
    }
  end

  defp generate_id do
    "RES-" <> (:crypto.strong_rand_bytes(8) |> Base.encode16())
  end
end
```
