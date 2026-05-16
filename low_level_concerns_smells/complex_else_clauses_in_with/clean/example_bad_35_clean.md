```elixir
defmodule Inventory.RestockManager do
  @moduledoc """
  Manages inventory restocking: SKU validation, supplier order placement,
  stock ledger adjustment, and warehouse notification.
  """

  alias Inventory.{SkuRegistry, SupplierGateway, StockLedger, WarehouseNotifier}
  require Logger

  @min_restock_qty 1
  @max_restock_qty 10_000

  @doc """
  Restocks `quantity` units of `sku` from `supplier_id`.

  Returns `{:ok, restock}` or a domain-specific error.
  """
  @spec restock_item(String.t(), String.t(), pos_integer()) ::
          {:ok, map()}
          | {:error, :sku_not_found}
          | {:error, :supplier_unavailable}
          | {:error, :ledger_conflict}
          | {:error, :notification_failed}
          | {:error, :invalid_quantity}
  def restock_item(sku, supplier_id, quantity) do
    cond do
      quantity < @min_restock_qty ->
        {:error, :invalid_quantity}

      quantity > @max_restock_qty ->
        {:error, :invalid_quantity}

      true ->
        with {:ok, sku_record} <- SkuRegistry.lookup(sku),
             {:ok, order}      <- SupplierGateway.place_order(supplier_id, sku_record, quantity),
             {:ok, entry}      <- StockLedger.apply_restock(%{
                                    sku:          sku,
                                    quantity:     quantity,
                                    supplier_ref: order.reference,
                                    expected_at:  order.estimated_delivery
                                  }),
             :ok               <- WarehouseNotifier.notify_incoming(entry) do
          restock = %{
            id:           entry.id,
            sku:          sku,
            quantity:     quantity,
            supplier_id:  supplier_id,
            order_ref:    order.reference,
            expected_at:  order.estimated_delivery,
            created_at:   DateTime.utc_now()
          }

          Logger.info("Restock #{restock.id} created: #{quantity}x #{sku} from #{supplier_id}")
          {:ok, restock}
        else
          {:error, :not_found} ->
            Logger.warn("SKU #{sku} not found in registry")
            {:error, :sku_not_found}

          {:error, :unavailable, reason} ->
            Logger.warn("Supplier #{supplier_id} unavailable: #{reason}")
            {:error, :supplier_unavailable}

          {:error, :conflict, detail} ->
            Logger.error("Ledger conflict on restock: #{inspect(detail)}")
            {:error, :ledger_conflict}

          {:error, :notify, reason} ->
            Logger.error("Warehouse notification failed: #{inspect(reason)}")
            {:error, :notification_failed}
        end
    end
  end
end
```
