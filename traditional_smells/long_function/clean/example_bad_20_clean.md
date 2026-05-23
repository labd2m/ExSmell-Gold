```elixir
defmodule Logistics.FulfillmentCoordinator do
  @moduledoc """
  Coordinates the fulfillment of a confirmed order by allocating stock from
  available warehouses, generating pick lists, and initiating shipment records.
  """

  alias Logistics.{Shipment, PickList, PickItem, WarehouseStock, Repo, EventBus}
  alias Orders.Order
  alias Inventory.StockManager
  alias Notifications.Dispatcher
  require Logger

  @allocation_strategy :nearest_warehouse

  def fulfill(%Order{} = order) do
    Logger.info("Starting fulfillment for order=#{order.id}")

    # --- Validate order is fulfillable ---
    if order.status not in [:paid, :processing] do
      {:error, {:unfulfillable_status, order.status}}
    else
      order = Repo.preload(order, :items)

      # --- Allocate stock per item ---
      allocation_results =
        Enum.map(order.items, fn item ->
          # Find warehouse(s) with sufficient stock
          candidates =
            WarehouseStock
            |> WarehouseStock.for_sku(item.sku)
            |> WarehouseStock.with_available_qty(item.quantity)
            |> WarehouseStock.order_by(@allocation_strategy, order.shipping_address)
            |> Repo.all()

          case candidates do
            [] ->
              {:error, item.sku, :out_of_stock}

            [best | _] ->
              # Reserve stock
              case StockManager.reserve(item.sku, item.quantity, warehouse_id: best.warehouse_id) do
                {:ok, reservation_id} ->
                  {:ok, item.sku, item.quantity, best.warehouse_id, reservation_id}

                {:error, reason} ->
                  {:error, item.sku, reason}
              end
          end
        end)

      # --- Check for allocation failures ---
      failures = Enum.filter(allocation_results, fn
        {:error, _, _} -> true
        _              -> false
      end)

      if failures != [] do
        # Roll back successful reservations
        Enum.each(allocation_results, fn
          {:ok, sku, qty, wh_id, _res_id} ->
            StockManager.release_reservation(sku, qty, warehouse_id: wh_id)
          _ ->
            :ok
        end)

        failed_skus = Enum.map(failures, fn {:error, sku, _} -> sku end)
        Logger.warning("Fulfillment allocation failed for order #{order.id}: #{inspect(failed_skus)}")
        {:error, {:stock_allocation_failed, failed_skus}}
      else
        # --- Group allocations by warehouse ---
        by_warehouse =
          Enum.group_by(allocation_results, fn {:ok, _sku, _qty, wh_id, _} -> wh_id end)

        shipments_and_picklists =
          Enum.map(by_warehouse, fn {warehouse_id, allocs} ->
            # --- Create shipment record ---
            {:ok, shipment} =
              Repo.insert(Shipment.changeset(%Shipment{}, %{
                order_id: order.id,
                warehouse_id: warehouse_id,
                status: :pending_pick,
                created_at: DateTime.utc_now()
              }))

            # --- Create pick list ---
            {:ok, pick_list} =
              Repo.insert(%PickList{
                shipment_id: shipment.id,
                warehouse_id: warehouse_id,
                status: :open,
                created_at: DateTime.utc_now()
              })

            # --- Add pick items ---
            Enum.each(allocs, fn {:ok, sku, qty, _wh_id, reservation_id} ->
              Repo.insert!(%PickItem{
                pick_list_id: pick_list.id,
                sku: sku,
                quantity: qty,
                reservation_id: reservation_id,
                status: :pending
              })
            end)

            {shipment, pick_list}
          end)

        # --- Update order status ---
        order
        |> Order.changeset(%{status: :in_fulfillment, fulfillment_started_at: DateTime.utc_now()})
        |> Repo.update!()

        # --- Publish fulfillment event ---
        EventBus.publish("order.fulfillment_started", %{
          order_id: order.id,
          shipment_ids: Enum.map(shipments_and_picklists, fn {s, _} -> s.id end)
        })

        # --- Notify customer ---
        Dispatcher.dispatch(order.user_id, %{
          type: "order_in_fulfillment",
          payload: %{order_id: order.id}
        })

        Logger.info("Fulfillment initiated for order #{order.id}, #{length(shipments_and_picklists)} shipment(s) created")
        {:ok, %{order: order, shipments: Enum.map(shipments_and_picklists, &elem(&1, 0))}}
      end
    end
  end

  def complete_pick(pick_list_id) do
    case Repo.get(PickList, pick_list_id) do
      nil  -> {:error, :not_found}
      list -> list |> PickList.changeset(%{status: :completed}) |> Repo.update()
    end
  end
end
```
