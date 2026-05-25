# Code Smell Annotation

- **Smell name:** Large Class (Large Module)
- **Expected smell location:** The entire `InventoryManager` module
- **Affected function(s):** `receive_stock/3`, `reserve_stock/2`, `release_reservation/1`, `fulfill_reservation/1`, `reorder_if_needed/1`, `adjust_price/3`, `get_pricing_tier/2`, `log_movement/4`, `stock_report/1`, `expiry_report/0`
- **Short explanation:** `InventoryManager` combines stock receiving, reservation lifecycle, automated reordering, dynamic pricing, movement audit logging, and reporting into one module. These represent distinct inventory sub-domains — each of which should be its own module (e.g., `StockReceiver`, `ReservationStore`, `ReorderPolicy`, `PricingEngine`, `MovementLog`, `InventoryReports`).

```elixir
# VALIDATION: SMELL START - Large Class (Large Module)
# VALIDATION: This is a smell because InventoryManager handles stock receiving,
# reservation management, automated reordering triggers, price adjustments,
# movement audit logging, and multiple report types — all distinct business
# concerns forced into one large, incoherent module.
defmodule MyApp.InventoryManager do
  @moduledoc """
  Manages product inventory including stock levels, reservations,
  pricing adjustments, reordering, and inventory reporting.
  """

  require Logger
  import Ecto.Query

  alias MyApp.Repo
  alias MyApp.Inventory.{StockItem, StockReservation, MovementLog, PriceHistory}
  alias MyApp.Products.Product
  alias MyApp.Purchasing.PurchaseOrder

  @reorder_multiplier    3
  @low_stock_threshold   10

  # -------------------------------------------------------------------
  # Stock receiving
  # -------------------------------------------------------------------

  def receive_stock(product_id, quantity, opts \\ []) when quantity > 0 do
    supplier_id  = opts[:supplier_id]
    lot_number   = opts[:lot_number]
    expires_on   = opts[:expires_on]
    cost_per_unit = opts[:cost_per_unit]

    item = get_or_create_stock_item(product_id)

    updated =
      item
      |> StockItem.changeset(%{
           quantity_on_hand: item.quantity_on_hand + quantity,
           last_received_at: DateTime.utc_now()
         })
      |> Repo.update!()

    log_movement(product_id, :receipt, quantity, %{
      supplier_id:   supplier_id,
      lot_number:    lot_number,
      expires_on:    expires_on,
      cost_per_unit: cost_per_unit
    })

    reorder_if_needed(updated)
    {:ok, updated}
  end

  defp get_or_create_stock_item(product_id) do
    case Repo.get_by(StockItem, product_id: product_id) do
      nil  -> Repo.insert!(%StockItem{product_id: product_id, quantity_on_hand: 0, quantity_reserved: 0})
      item -> item
    end
  end

  # -------------------------------------------------------------------
  # Reservation management
  # -------------------------------------------------------------------

  def reserve_stock(product_id, quantity) when quantity > 0 do
    item = Repo.get_by!(StockItem, product_id: product_id)
    available = item.quantity_on_hand - item.quantity_reserved

    if available >= quantity do
      reservation =
        Repo.insert!(%StockReservation{
          product_id:  product_id,
          quantity:    quantity,
          reserved_at: DateTime.utc_now(),
          expires_at:  DateTime.add(DateTime.utc_now(), 30 * 60, :second),
          status:      :active
        })

      Repo.update!(StockItem.changeset(item, %{quantity_reserved: item.quantity_reserved + quantity}))
      log_movement(product_id, :reservation, quantity, %{reservation_id: reservation.id})
      {:ok, reservation}
    else
      {:error, :insufficient_stock}
    end
  end

  def release_reservation(%StockReservation{status: :active} = reservation) do
    item = Repo.get_by!(StockItem, product_id: reservation.product_id)

    Repo.update!(StockItem.changeset(item, %{
      quantity_reserved: max(0, item.quantity_reserved - reservation.quantity)
    }))

    Repo.update!(StockReservation.changeset(reservation, %{status: :released}))
    log_movement(reservation.product_id, :release, reservation.quantity, %{})
    :ok
  end

  def release_reservation(_), do: {:error, :not_active}

  def fulfill_reservation(%StockReservation{status: :active} = reservation) do
    item = Repo.get_by!(StockItem, product_id: reservation.product_id)

    Repo.update!(StockItem.changeset(item, %{
      quantity_on_hand:  item.quantity_on_hand - reservation.quantity,
      quantity_reserved: max(0, item.quantity_reserved - reservation.quantity)
    }))

    Repo.update!(StockReservation.changeset(reservation, %{status: :fulfilled, fulfilled_at: DateTime.utc_now()}))
    log_movement(reservation.product_id, :fulfillment, reservation.quantity, %{reservation_id: reservation.id})

    item_after = Repo.get_by!(StockItem, product_id: reservation.product_id)
    reorder_if_needed(item_after)
    :ok
  end

  def fulfill_reservation(_), do: {:error, :not_active}

  # -------------------------------------------------------------------
  # Automated reordering
  # -------------------------------------------------------------------

  def reorder_if_needed(%StockItem{} = item) do
    available = item.quantity_on_hand - item.quantity_reserved

    if available <= @low_stock_threshold do
      product = Repo.get!(Product, item.product_id)

      unless pending_reorder_exists?(item.product_id) do
        qty_to_order = (product.reorder_quantity || @low_stock_threshold) * @reorder_multiplier

        Repo.insert!(%PurchaseOrder{
          product_id:   item.product_id,
          quantity:     qty_to_order,
          status:       :pending,
          triggered_by: :low_stock
        })

        Logger.info("Auto-reorder triggered for product #{item.product_id}, qty #{qty_to_order}")
      end
    end
  end

  defp pending_reorder_exists?(product_id) do
    Repo.exists?(from po in PurchaseOrder,
      where: po.product_id == ^product_id and po.status in [:pending, :ordered])
  end

  # -------------------------------------------------------------------
  # Pricing management
  # -------------------------------------------------------------------

  def adjust_price(product_id, new_price_cents, reason) when new_price_cents > 0 do
    product = Repo.get!(Product, product_id)

    Repo.insert!(%PriceHistory{
      product_id:    product_id,
      old_price:     product.price_cents,
      new_price:     new_price_cents,
      changed_at:    DateTime.utc_now(),
      reason:        reason
    })

    Repo.update!(Product.changeset(product, %{price_cents: new_price_cents}))
    {:ok, new_price_cents}
  end

  def get_pricing_tier(product_id, quantity) do
    product = Repo.get!(Product, product_id)

    cond do
      quantity >= 100 -> product.price_cents * 0.75
      quantity >= 50  -> product.price_cents * 0.85
      quantity >= 20  -> product.price_cents * 0.92
      true            -> product.price_cents * 1.0
    end
    |> round()
  end

  # -------------------------------------------------------------------
  # Movement audit log
  # -------------------------------------------------------------------

  def log_movement(product_id, movement_type, quantity, metadata) do
    Repo.insert!(%MovementLog{
      product_id:    product_id,
      movement_type: movement_type,
      quantity:      quantity,
      metadata:      metadata,
      occurred_at:   DateTime.utc_now()
    })
  end

  # -------------------------------------------------------------------
  # Reporting
  # -------------------------------------------------------------------

  def stock_report(warehouse_id) do
    from(si in StockItem,
      join: p in Product, on: p.id == si.product_id,
      where: p.warehouse_id == ^warehouse_id,
      select: %{
        product_id:   si.product_id,
        sku:          p.sku,
        name:         p.name,
        on_hand:      si.quantity_on_hand,
        reserved:     si.quantity_reserved,
        available:    si.quantity_on_hand - si.quantity_reserved,
        low_stock:    si.quantity_on_hand - si.quantity_reserved <= @low_stock_threshold
      }
    )
    |> Repo.all()
  end

  def expiry_report do
    cutoff = Date.add(Date.utc_today(), 30)

    from(ml in MovementLog,
      where: ml.movement_type == :receipt
        and fragment("?->>'expires_on' IS NOT NULL", ml.metadata)
        and fragment("(?->>'expires_on')::date <= ?", ml.metadata, ^cutoff),
      order_by: [asc: fragment("(?->>'expires_on')::date", ml.metadata)]
    )
    |> Repo.all()
  end
end
# VALIDATION: SMELL END
```
