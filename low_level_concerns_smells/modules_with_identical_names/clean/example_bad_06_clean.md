```elixir
# ── file: lib/inventory/stock.ex ─────────────────────────────────────────────

defmodule Inventory.Stock do
  @moduledoc """
  Manages real-time stock reservation for warehouse SKUs.
  Called by the order pipeline before payment capture to hold inventory.
  """

  alias Inventory.{Warehouse, ReservationStore, SKU}

  @reservation_ttl_minutes 15

  @type reservation :: %{
          id: String.t(),
          sku_id: String.t(),
          warehouse_id: String.t(),
          quantity: pos_integer(),
          reserved_at: DateTime.t(),
          expires_at: DateTime.t(),
          order_ref: String.t()
        }

  @spec reserve(String.t(), pos_integer()) ::
          {:ok, reservation()} | {:error, :insufficient_stock | :sku_not_found}
  def reserve(sku_id, quantity) do
    with {:ok, sku} <- SKU.fetch(sku_id),
         {:ok, warehouse} <- Warehouse.nearest_with_stock(sku_id, quantity),
         :ok <- check_availability(warehouse, sku_id, quantity) do
      now = DateTime.utc_now()
      expires_at = DateTime.add(now, @reservation_ttl_minutes * 60, :second)

      reservation = %{
        id: generate_reservation_id(),
        sku_id: sku_id,
        warehouse_id: warehouse.id,
        quantity: quantity,
        reserved_at: now,
        expires_at: expires_at,
        order_ref: nil
      }

      ReservationStore.put(reservation)
      decrement_available(warehouse.id, sku_id, quantity)

      {:ok, reservation}
    end
  end

  @spec release(String.t()) :: :ok | {:error, :not_found}
  def release(reservation_id) do
    case ReservationStore.get(reservation_id) do
      {:ok, reservation} ->
        ReservationStore.delete(reservation_id)
        increment_available(reservation.warehouse_id, reservation.sku_id, reservation.quantity)
        :ok

      {:error, :not_found} = err ->
        err
    end
  end

  @spec confirm(String.t(), String.t()) :: {:ok, reservation()} | {:error, term()}
  def confirm(reservation_id, order_ref) do
    case ReservationStore.get(reservation_id) do
      {:ok, %{expires_at: exp} = res} ->
        if DateTime.compare(exp, DateTime.utc_now()) == :gt do
          updated = Map.put(res, :order_ref, order_ref)
          ReservationStore.put(updated)
          {:ok, updated}
        else
          {:error, :reservation_expired}
        end

      {:error, _} = err ->
        err
    end
  end

  defp check_availability(warehouse, sku_id, quantity) do
    available = Warehouse.available_qty(warehouse.id, sku_id)
    if available >= quantity, do: :ok, else: {:error, :insufficient_stock}
  end

  defp decrement_available(warehouse_id, sku_id, qty) do
    Warehouse.adjust_available(warehouse_id, sku_id, -qty)
  end

  defp increment_available(warehouse_id, sku_id, qty) do
    Warehouse.adjust_available(warehouse_id, sku_id, qty)
  end

  defp generate_reservation_id do
    "RSV-" <> (:crypto.strong_rand_bytes(8) |> Base.encode16())
  end
end


# ── file: lib/inventory/stock_replenishment.ex ───────────────────────────────

defmodule Inventory.Stock do
  @moduledoc """
  Handles purchase-order driven stock replenishment and warehouse receiving.
  Triggered by the procurement service when supplier deliveries arrive.
  """

  alias Inventory.{Warehouse, PurchaseOrder, SKU, AuditLog}

  @type receipt :: %{
          id: String.t(),
          purchase_order_id: String.t(),
          sku_id: String.t(),
          warehouse_id: String.t(),
          quantity_received: pos_integer(),
          received_at: DateTime.t(),
          receiver_id: String.t()
        }

  @spec replenish(String.t(), map()) :: {:ok, receipt()} | {:error, term()}
  def replenish(purchase_order_id, attrs) do
    with {:ok, po} <- PurchaseOrder.fetch(purchase_order_id),
         :ok <- validate_po_open(po),
         {:ok, sku} <- SKU.fetch(attrs[:sku_id]),
         {:ok, warehouse} <- Warehouse.fetch(attrs[:warehouse_id]) do
      qty = attrs[:quantity]

      receipt = %{
        id: generate_receipt_id(),
        purchase_order_id: purchase_order_id,
        sku_id: sku.id,
        warehouse_id: warehouse.id,
        quantity_received: qty,
        received_at: DateTime.utc_now(),
        receiver_id: attrs[:receiver_id]
      }

      Warehouse.adjust_on_hand(warehouse.id, sku.id, qty)
      PurchaseOrder.record_receipt(po, receipt)

      AuditLog.write(:stock_replenished, %{
        sku_id: sku.id,
        warehouse_id: warehouse.id,
        quantity: qty
      })

      {:ok, receipt}
    end
  end

  @spec adjust(String.t(), String.t(), integer(), String.t()) :: :ok | {:error, term()}
  def adjust(warehouse_id, sku_id, delta, reason) do
    with {:ok, _} <- Warehouse.fetch(warehouse_id),
         {:ok, _} <- SKU.fetch(sku_id) do
      Warehouse.adjust_on_hand(warehouse_id, sku_id, delta)

      AuditLog.write(:stock_adjusted, %{
        warehouse_id: warehouse_id,
        sku_id: sku_id,
        delta: delta,
        reason: reason
      })

      :ok
    end
  end

  defp validate_po_open(%{status: :open}), do: :ok
  defp validate_po_open(_), do: {:error, :purchase_order_not_open}

  defp generate_receipt_id do
    "RCP-" <> (:crypto.strong_rand_bytes(6) |> Base.encode16())
  end
end
```
