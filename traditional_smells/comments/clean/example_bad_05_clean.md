```elixir
defmodule InventoryManager do
  @moduledoc """
  Manages stock levels, reservations, and replenishment workflows for
  the warehouse management system.
  """

  alias InventoryManager.{StockItem, Reservation, ReplenishmentQueue, AuditEntry}

  @reservation_expiry_minutes 30

  @doc """
  Returns the current available quantity for a SKU across all warehouses.
  """
  def available_quantity(sku) do
    StockItem.total_available(sku)
  end

  @doc """
  Lists all active (non-expired, non-fulfilled) reservations for a given SKU.
  """
  def active_reservations(sku) do
    Reservation.active_for_sku(sku)
  end

  # reserve_stock/3
  #
  # Atomically reserves `quantity` units of `sku` for a given order reference.
  # The reservation prevents the units from being allocated to other orders
  # for @reservation_expiry_minutes minutes.
  #
  # This function acquires a row-level advisory lock on the StockItem record
  # to prevent double-reservation under concurrent requests.
  #
  # Steps performed:
  #   1. Lock StockItem row for the given SKU.
  #   2. Check that available_quantity >= requested quantity.
  #   3. Decrement available_quantity and create a Reservation record.
  #   4. Enqueue a ReplenishmentQueue job if stock falls below reorder_point.
  #   5. Write an AuditEntry for traceability.
  #
  # Parameters:
  #   sku          - string product identifier
  #   quantity     - positive integer units to reserve
  #   order_ref    - string external order reference used for idempotency
  #
  # Returns {:ok, %Reservation{}} or {:error, :insufficient_stock | :already_reserved | reason}.
  # plain comments to convey its concurrency contract, steps, parameters, and
  # return values instead of an @doc attribute. The documentation is therefore
  # invisible to ExDoc and IEx.
  def reserve_stock(sku, quantity, order_ref) do
    Repo.transaction(fn ->
      with {:ok, item} <- StockItem.lock_for_update(sku),
           :ok <- check_idempotency(order_ref),
           :ok <- validate_availability(item, quantity),
           {:ok, updated_item} <- decrement_stock(item, quantity),
           {:ok, reservation} <- Reservation.create(sku, quantity, order_ref, expiry_minutes: @reservation_expiry_minutes),
           :ok <- maybe_enqueue_replenishment(updated_item),
           {:ok, _} <- AuditEntry.record(:reservation, sku, quantity, order_ref) do
        reservation
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  @doc """
  Releases a previously created reservation, returning the units to available stock.
  """
  def release_reservation(reservation_id) do
    Repo.transaction(fn ->
      with {:ok, reservation} <- Reservation.fetch(reservation_id),
           {:ok, _} <- StockItem.increment(reservation.sku, reservation.quantity),
           {:ok, _} <- Reservation.mark_released(reservation) do
        :ok
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  @doc """
  Fulfils a reservation by converting it to a permanent stock deduction.
  """
  def fulfil_reservation(reservation_id) do
    with {:ok, reservation} <- Reservation.fetch(reservation_id),
         {:ok, _} <- Reservation.mark_fulfilled(reservation) do
      AuditEntry.record(:fulfilment, reservation.sku, reservation.quantity, reservation.order_ref)
    end
  end

  defp check_idempotency(order_ref) do
    case Reservation.find_by_order_ref(order_ref) do
      nil -> :ok
      _ -> {:error, :already_reserved}
    end
  end

  defp validate_availability(%StockItem{available_quantity: avail}, quantity)
       when avail >= quantity,
       do: :ok

  defp validate_availability(_, _), do: {:error, :insufficient_stock}

  defp decrement_stock(item, quantity) do
    item
    |> StockItem.changeset(%{available_quantity: item.available_quantity - quantity})
    |> Repo.update()
  end

  defp maybe_enqueue_replenishment(%StockItem{available_quantity: avail, reorder_point: rp, sku: sku})
       when avail < rp do
    ReplenishmentQueue.enqueue(sku)
  end

  defp maybe_enqueue_replenishment(_), do: :ok
end
```
