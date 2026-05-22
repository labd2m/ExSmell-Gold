```elixir
defmodule MyApp.InventoryManager do
  @moduledoc """
  Manages product stock levels, reservations, and restocking workflows
  for the MyApp e-commerce platform.
  """

  alias MyApp.Repo
  alias MyApp.Inventory.{Product, Reservation, StockMovement}
  alias Ecto.Multi

  require Logger

  @reservation_ttl_minutes 30

  @doc """
  Returns current available stock for a product, accounting for active reservations.
  """
  def available_stock(product_id) do
    product = Repo.get!(Product, product_id)
    reserved = active_reservation_total(product_id)
    max(0, product.stock_quantity - reserved)
  end


  # reserve_stock/3
  #
  # Attempts to reserve `quantity` units of product `product_id` for `order_id`.
  # A reservation is a temporary hold that expires after @reservation_ttl_minutes
  # if not confirmed.
  #
  # Rules:
  #   - If available stock is insufficient, returns {:error, :insufficient_stock}.
  #   - If a reservation already exists for the same order/product, returns
  #     {:error, :duplicate_reservation}.
  #   - Inserts a stock movement record for audit purposes.
  #
  # Returns:
  #   {:ok, %Reservation{}} on success
  #   {:error, :insufficient_stock}
  #   {:error, :duplicate_reservation}
  #   {:error, changeset} on persistence failure
  def reserve_stock(product_id, order_id, quantity) do
    with :ok <- check_no_duplicate(product_id, order_id),
         :ok <- check_availability(product_id, quantity) do
      Multi.new()
      |> Multi.insert(:reservation, build_reservation(product_id, order_id, quantity))
      |> Multi.insert(:movement, build_movement(product_id, :reserve, quantity))
      |> Repo.transaction()
      |> case do
        {:ok, %{reservation: reservation}} -> {:ok, reservation}
        {:error, _step, reason, _changes} -> {:error, reason}
      end
    end
  end

  @doc """
  Confirms a reservation, permanently decrementing stock and removing the hold.
  """
  def confirm_reservation(reservation_id) do
    case Repo.get(Reservation, reservation_id) do
      nil ->
        {:error, :not_found}

      reservation ->
        Multi.new()
        |> Multi.update(:reservation, Reservation.changeset(reservation, %{status: :confirmed}))
        |> Multi.update(:product, decrement_stock(reservation.product_id, reservation.quantity))
        |> Repo.transaction()
        |> case do
          {:ok, %{reservation: r}} -> {:ok, r}
          {:error, _step, reason, _changes} -> {:error, reason}
        end
    end
  end

  @doc """
  Expires all reservations whose TTL has elapsed and releases their stock holds.
  Intended to be called by a periodic scheduler.
  """
  def expire_stale_reservations do
    cutoff = DateTime.add(DateTime.utc_now(), -@reservation_ttl_minutes * 60, :second)

    stale =
      Reservation
      |> Reservation.pending_before(cutoff)
      |> Repo.all()

    Enum.each(stale, fn r ->
      r
      |> Reservation.changeset(%{status: :expired})
      |> Repo.update()

      Logger.info("Expired reservation #{r.id} for product #{r.product_id}")
    end)

    {:ok, length(stale)}
  end

  # --- Private helpers ---

  defp check_no_duplicate(product_id, order_id) do
    case Repo.get_by(Reservation, product_id: product_id, order_id: order_id, status: :pending) do
      nil -> :ok
      _existing -> {:error, :duplicate_reservation}
    end
  end

  defp check_availability(product_id, quantity) do
    if available_stock(product_id) >= quantity do
      :ok
    else
      {:error, :insufficient_stock}
    end
  end

  defp active_reservation_total(product_id) do
    Reservation
    |> Reservation.pending_for_product(product_id)
    |> Repo.aggregate(:sum, :quantity) || 0
  end

  defp build_reservation(product_id, order_id, quantity) do
    Reservation.changeset(%Reservation{}, %{
      product_id: product_id,
      order_id: order_id,
      quantity: quantity,
      status: :pending
    })
  end

  defp build_movement(product_id, type, quantity) do
    StockMovement.changeset(%StockMovement{}, %{
      product_id: product_id,
      movement_type: type,
      quantity: quantity,
      occurred_at: DateTime.utc_now()
    })
  end

  defp decrement_stock(product_id, quantity) do
    product = Repo.get!(Product, product_id)
    Product.changeset(product, %{stock_quantity: product.stock_quantity - quantity})
  end
end
```
