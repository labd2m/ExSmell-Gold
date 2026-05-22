```elixir
defmodule MyApp.Inventory.InventoryManager do
  @moduledoc """
  Manages stock levels, reservations, and restocking workflows
  for warehouse and fulfilment operations.
  """

  alias MyApp.Repo
  alias MyApp.Inventory.{Product, StockReservation, StockMovement, Warehouse}
  import Ecto.Query

  require Logger

  @reservation_ttl_minutes 30

  @doc """
  Returns the current available quantity of a product in a given warehouse,
  factoring in existing reservations.
  """
  def available_quantity(product_id, warehouse_id) do
    product = Repo.get!(Product, product_id)

    reserved =
      StockReservation
      |> where([r], r.product_id == ^product_id and r.warehouse_id == ^warehouse_id and r.status == :active)
      |> select([r], sum(r.quantity))
      |> Repo.one() || 0

    stock =
      product.stock_levels
      |> Enum.find(%{quantity: 0}, &(&1.warehouse_id == warehouse_id))
      |> Map.get(:quantity)

    max(0, stock - reserved)
  end

  # Attempts to reserve a quantity of a product in a specific warehouse.
  #
  # Params:
  #   product_id   - integer ID of the product to reserve.
  #   warehouse_id - integer ID of the warehouse from which to draw stock.
  #   quantity     - positive integer representing the number of units to reserve.
  #
  # Behaviour:
  #   Checks real-time available stock (on-hand minus existing active reservations).
  #   If sufficient stock exists, inserts a StockReservation record with a TTL
  #   of @reservation_ttl_minutes. Expired reservations are not automatically cleared
  #   here; see ReservationCleaner for that.
  #
  # Returns:
  #   {:ok, reservation}    - reservation created successfully.
  #   {:error, :insufficient_stock} - not enough stock available.
  #   {:error, reason}      - database or validation failure.
  def reserve_stock(product_id, warehouse_id, quantity) when quantity > 0 do
    available = available_quantity(product_id, warehouse_id)

    if available < quantity do
      Logger.warning("Insufficient stock for reservation",
        product_id: product_id,
        requested: quantity,
        available: available
      )

      {:error, :insufficient_stock}
    else
      expires_at =
        DateTime.utc_now()
        |> DateTime.add(@reservation_ttl_minutes * 60, :second)

      attrs = %{
        product_id: product_id,
        warehouse_id: warehouse_id,
        quantity: quantity,
        status: :active,
        expires_at: expires_at
      }

      case StockReservation.changeset(%StockReservation{}, attrs) |> Repo.insert() do
        {:ok, reservation} ->
          Logger.info("Stock reserved",
            reservation_id: reservation.id,
            product_id: product_id,
            quantity: quantity
          )
          {:ok, reservation}

        {:error, changeset} ->
          {:error, changeset}
      end
    end
  end

  def reserve_stock(_, _, quantity) when quantity <= 0 do
    {:error, :invalid_quantity}
  end

  @doc """
  Confirms and deducts a reservation from on-hand stock.

  Call this once an order is actually placed. The reservation is marked
  `:confirmed` and a `StockMovement` record is created to track the deduction.
  """
  def confirm_reservation(reservation_id) do
    with {:ok, reservation} <- fetch_active_reservation(reservation_id) do
      Repo.transaction(fn ->
        {:ok, confirmed} =
          reservation
          |> StockReservation.changeset(%{status: :confirmed})
          |> Repo.update()

        {:ok, _movement} =
          StockMovement.changeset(%StockMovement{}, %{
            product_id: reservation.product_id,
            warehouse_id: reservation.warehouse_id,
            quantity: -reservation.quantity,
            reason: :reservation_confirmed,
            reference_id: reservation.id
          })
          |> Repo.insert()

        confirmed
      end)
    end
  end

  @doc """
  Releases an active reservation without consuming the stock.
  """
  def release_reservation(reservation_id) do
    with {:ok, reservation} <- fetch_active_reservation(reservation_id) do
      reservation
      |> StockReservation.changeset(%{status: :released})
      |> Repo.update()
    end
  end

  # --- Private helpers ---

  defp fetch_active_reservation(id) do
    case Repo.get(StockReservation, id) do
      %StockReservation{status: :active} = r -> {:ok, r}
      nil -> {:error, :reservation_not_found}
      _ -> {:error, :reservation_not_active}
    end
  end
end
```
