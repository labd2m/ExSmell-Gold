# Annotated Example — Code Smell: Comments

| Field | Value |
|---|---|
| **Smell name** | Comments |
| **Expected smell location** | `InventoryManager.reserve_stock/3` |
| **Affected function(s)** | `reserve_stock/3` |
| **Short explanation** | `reserve_stock/3` is described entirely through plain `#` comment lines scattered before the function, rather than an `@doc` attribute that tooling can process. |

```elixir
defmodule MyApp.InventoryManager do
  @moduledoc """
  Manages warehouse stock levels, reservations, and replenishment
  triggers for the MyApp e-commerce platform.
  """

  import Ecto.Query
  alias MyApp.{Repo, Product, StockReservation, ReplenishmentOrder}
  require Logger

  @reservation_ttl_minutes 15
  @low_stock_threshold 10
  @replenishment_qty 100

  # VALIDATION: SMELL START - Comments
  # VALIDATION: This is a smell because the developer wrote the documentation for
  # VALIDATION: `reserve_stock/3` as plain `#` comment lines rather than using
  # VALIDATION: the `@doc` attribute. This documentation will not appear in ExDoc
  # VALIDATION: or when calling `h MyApp.InventoryManager.reserve_stock/3` in IEx.

  # reserve_stock/3
  # Attempts to reserve a given quantity of a product for an order.
  #
  # Parameters:
  #   product_id  - integer, the ID of the product to reserve
  #   quantity    - positive integer, number of units to reserve
  #   order_id    - string, the order reference requesting the reservation
  #
  # Reserves stock by decrementing the available quantity atomically,
  # creating a StockReservation record that expires in @reservation_ttl_minutes.
  # If available stock drops below @low_stock_threshold after the reservation,
  # a replenishment order is automatically triggered.
  #
  # Returns {:ok, reservation} or {:error, :insufficient_stock} or {:error, :product_not_found}.

  # VALIDATION: SMELL END
  def reserve_stock(product_id, quantity, order_id)
      when is_integer(quantity) and quantity > 0 do
    Repo.transaction(fn ->
      case Repo.get(Product, product_id, lock: "FOR UPDATE") do
        nil ->
          Repo.rollback(:product_not_found)

        %Product{available_qty: available} when available < quantity ->
          Repo.rollback(:insufficient_stock)

        product ->
          expires_at =
            DateTime.add(DateTime.utc_now(), @reservation_ttl_minutes * 60, :second)

          {:ok, reservation} =
            %StockReservation{}
            |> StockReservation.changeset(%{
              product_id: product.id,
              order_id: order_id,
              quantity: quantity,
              expires_at: expires_at,
              status: :active
            })
            |> Repo.insert()

          new_qty = product.available_qty - quantity

          product
          |> Product.changeset(%{available_qty: new_qty})
          |> Repo.update!()

          if new_qty < @low_stock_threshold do
            trigger_replenishment(product)
          end

          Logger.info(
            "[Inventory] Reserved #{quantity} units of product #{product_id} for order #{order_id}"
          )

          reservation
      end
    end)
    |> case do
      {:ok, reservation} -> {:ok, reservation}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Releases a previously created stock reservation.

  Sets the reservation status to `:released` and returns the quantity
  back to the product's available pool. Returns `{:ok, product}` or
  `{:error, :reservation_not_found}`.
  """
  def release_reservation(reservation_id) do
    Repo.transaction(fn ->
      case Repo.get(StockReservation, reservation_id) do
        nil ->
          Repo.rollback(:reservation_not_found)

        reservation ->
          reservation
          |> StockReservation.changeset(%{status: :released})
          |> Repo.update!()

          product = Repo.get!(Product, reservation.product_id, lock: "FOR UPDATE")

          product
          |> Product.changeset(%{available_qty: product.available_qty + reservation.quantity})
          |> Repo.update!()
      end
    end)
  end

  @doc """
  Expires all stock reservations whose `expires_at` timestamp is in the past
  and releases their quantities back to the available pool.

  Returns `{:ok, count}` with the number of reservations expired.
  """
  def expire_stale_reservations do
    now = DateTime.utc_now()

    stale =
      Repo.all(
        from(r in StockReservation,
          where: r.status == :active and r.expires_at < ^now
        )
      )

    count =
      Enum.reduce(stale, 0, fn reservation, acc ->
        case release_reservation(reservation.id) do
          {:ok, _} -> acc + 1
          _ -> acc
        end
      end)

    Logger.info("[Inventory] Expired #{count} stale reservations")
    {:ok, count}
  end

  ## Private

  defp trigger_replenishment(product) do
    existing =
      Repo.get_by(ReplenishmentOrder,
        product_id: product.id,
        status: :pending
      )

    unless existing do
      %ReplenishmentOrder{}
      |> ReplenishmentOrder.changeset(%{
        product_id: product.id,
        quantity: @replenishment_qty,
        status: :pending,
        requested_at: DateTime.utc_now()
      })
      |> Repo.insert()

      Logger.info("[Inventory] Replenishment order triggered for product #{product.id}")
    end
  end
end
```
