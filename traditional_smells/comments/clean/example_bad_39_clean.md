```elixir
defmodule InventoryManager do
  @moduledoc """
  Manages warehouse stock levels, reservations, and replenishment triggers
  for the fulfilment platform.
  """

  alias InventoryManager.{Reservation, StockEntry, WarehouseRepo}
  require Logger

  @low_stock_threshold 10
  @reservation_ttl_minutes 30

  @doc """
  Returns the current available stock for a given SKU across all warehouses,
  excluding any quantities held under active reservations.
  """
  def available_stock(sku) when is_binary(sku) do
    total = WarehouseRepo.total_quantity(sku)
    reserved = WarehouseRepo.reserved_quantity(sku)
    max(total - reserved, 0)
  end

  @doc """
  Triggers a replenishment request if stock for the given SKU falls below
  the configured low-stock threshold.
  """
  def maybe_trigger_replenishment(sku) when is_binary(sku) do
    if available_stock(sku) < @low_stock_threshold do
      Logger.info("Low stock detected for SKU #{sku}. Triggering replenishment.")
      WarehouseRepo.create_replenishment_request(sku)
    else
      :ok
    end
  end


  # Attempts to place a stock reservation for the given order.
  #
  # - sku:      binary string identifying the product SKU
  # - quantity: positive integer, number of units to reserve
  # - order_id: binary string, the order this reservation is associated with
  #
  # On success, returns {:ok, %Reservation{}} with a TTL of @reservation_ttl_minutes.
  # Returns {:error, :insufficient_stock} when available stock is less than quantity.
  # Returns {:error, :already_reserved} if an active reservation for this order+sku exists.
  def reserve_stock(sku, quantity, order_id)
      when is_binary(sku) and is_integer(quantity) and quantity > 0 and is_binary(order_id) do
    with :ok <- check_no_duplicate(sku, order_id),
         :ok <- check_availability(sku, quantity),
         {:ok, reservation} <- create_reservation(sku, quantity, order_id) do
      maybe_trigger_replenishment(sku)
      {:ok, reservation}
    end
  end


  @doc """
  Releases a previously created stock reservation by its reservation ID.
  """
  def release_reservation(reservation_id) when is_binary(reservation_id) do
    case WarehouseRepo.delete_reservation(reservation_id) do
      :ok ->
        Logger.info("Reservation #{reservation_id} released.")
        :ok

      {:error, :not_found} ->
        {:error, :reservation_not_found}
    end
  end

  @doc """
  Commits a reservation into a confirmed stock deduction, typically called
  after a successful payment capture.
  """
  def commit_reservation(reservation_id) when is_binary(reservation_id) do
    with {:ok, %Reservation{sku: sku, quantity: qty}} <-
           WarehouseRepo.fetch_reservation(reservation_id),
         :ok <- WarehouseRepo.deduct_stock(sku, qty),
         :ok <- WarehouseRepo.delete_reservation(reservation_id) do
      {:ok, :committed}
    end
  end

  @doc """
  Lists all expired reservations and removes them from the store.
  """
  def purge_expired_reservations do
    cutoff = DateTime.add(DateTime.utc_now(), -@reservation_ttl_minutes * 60, :second)

    expired =
      WarehouseRepo.list_reservations()
      |> Enum.filter(fn %Reservation{created_at: ts} -> DateTime.compare(ts, cutoff) == :lt end)

    Enum.each(expired, fn %Reservation{id: id} -> release_reservation(id) end)

    {:ok, length(expired)}
  end

  defp check_no_duplicate(sku, order_id) do
    case WarehouseRepo.find_reservation(sku, order_id) do
      nil -> :ok
      _ -> {:error, :already_reserved}
    end
  end

  defp check_availability(sku, quantity) do
    if available_stock(sku) >= quantity, do: :ok, else: {:error, :insufficient_stock}
  end

  defp create_reservation(sku, quantity, order_id) do
    entry = %StockEntry{sku: sku, quantity: quantity}
    WarehouseRepo.insert_reservation(entry, order_id)
  end
end
```
