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
