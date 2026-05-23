# Annotated Example — Duplicated Code

| Field | Value |
|---|---|
| **Smell name** | Duplicated Code |
| **Expected smell location** | `Inventory.StockManager.consume_stock/3` and `Inventory.StockManager.reserve_stock/3` |
| **Affected functions** | `consume_stock/3`, `reserve_stock/3` |
| **Short explanation** | Both functions independently replicate the reorder-alert logic (computing available units, comparing against the reorder threshold, and publishing a low-stock event). If the threshold calculation or the event payload changes, both functions must be updated in lockstep. |

```elixir
defmodule Inventory.StockManager do
  @moduledoc """
  Manages stock levels, reservations, and replenishment triggers for the
  warehouse inventory system.
  """

  alias Inventory.{StockLedger, Product, Reservation, EventBus}

  @reorder_buffer_factor 1.2

  # ---------------------------------------------------------------------------
  # Stock consumption (fulfilment path)
  # ---------------------------------------------------------------------------

  @doc """
  Deducts `quantity` units of `sku` in `warehouse_id` from available stock.
  Triggers a reorder alert if stock falls below the product's reorder point.
  """
  def consume_stock(sku, warehouse_id, quantity) when quantity > 0 do
    with {:ok, product} <- Product.fetch(sku),
         {:ok, entry}   <- StockLedger.fetch(sku, warehouse_id),
         :ok            <- check_sufficient_stock(entry, quantity) do

      new_on_hand = entry.on_hand - quantity

      case StockLedger.update(entry, %{on_hand: new_on_hand}) do
        {:ok, updated} ->
          # VALIDATION: SMELL START - Duplicated Code
          # VALIDATION: This is a smell because the reorder-alert logic
          # (available units calculation and event publishing) is copy-pasted
          # verbatim from reserve_stock/3. A change to reorder threshold
          # logic must be made in both functions.
          available  = updated.on_hand - updated.reserved
          reorder_pt = round(product.reorder_quantity * @reorder_buffer_factor)

          if available <= reorder_pt do
            EventBus.publish(:low_stock_alert, %{
              sku:          sku,
              warehouse_id: warehouse_id,
              on_hand:      updated.on_hand,
              reserved:     updated.reserved,
              available:    available,
              reorder_at:   reorder_pt,
              triggered_by: :consumption
            })
          end
          # VALIDATION: SMELL END

          {:ok, updated}

        {:error, reason} ->
          {:error, {:ledger_update_failed, reason}}
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Stock reservation (checkout / pre-allocation path)
  # ---------------------------------------------------------------------------

  @doc """
  Reserves `quantity` units of `sku` in `warehouse_id` for a pending order.
  Also triggers a reorder alert when available stock falls below threshold.
  """
  def reserve_stock(sku, warehouse_id, quantity) when quantity > 0 do
    with {:ok, product} <- Product.fetch(sku),
         {:ok, entry}   <- StockLedger.fetch(sku, warehouse_id),
         :ok            <- check_sufficient_stock(entry, quantity) do

      new_reserved = entry.reserved + quantity
      reservation  = %Reservation{sku: sku, warehouse_id: warehouse_id, qty: quantity}

      case StockLedger.update(entry, %{reserved: new_reserved}) do
        {:ok, updated} ->
          Reservation.record(reservation)

          # VALIDATION: SMELL START - Duplicated Code
          # VALIDATION: This is a smell because the identical reorder-alert
          # block from consume_stock/3 is reproduced here. Both copies must
          # stay in sync whenever the reorder logic evolves.
          available  = updated.on_hand - updated.reserved
          reorder_pt = round(product.reorder_quantity * @reorder_buffer_factor)

          if available <= reorder_pt do
            EventBus.publish(:low_stock_alert, %{
              sku:          sku,
              warehouse_id: warehouse_id,
              on_hand:      updated.on_hand,
              reserved:     updated.reserved,
              available:    available,
              reorder_at:   reorder_pt,
              triggered_by: :reservation
            })
          end
          # VALIDATION: SMELL END

          {:ok, updated}

        {:error, reason} ->
          {:error, {:ledger_update_failed, reason}}
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp check_sufficient_stock(%{on_hand: on_hand, reserved: reserved}, qty) do
    if on_hand - reserved >= qty do
      :ok
    else
      {:error, :insufficient_stock}
    end
  end
end
```
