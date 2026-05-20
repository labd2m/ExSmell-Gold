```elixir
defmodule MyApp.LogisticsManager do
  @moduledoc """
  Central handler for logistics domain operations including shipments,
  inventory adjustments, and route management.
  """

  require Logger

  alias MyApp.Repo
  alias MyApp.Logistics.{Shipment, StockAdjustment, Route}
  alias MyApp.Carriers.DispatchClient
  alias MyApp.Warehouse.InventoryLedger
  alias MyApp.Routing.OptimizerService

  @doc """
  Handles a logistics operation.

  Dispatches to the correct logic based on the struct type provided.

  ## Examples

      iex> MyApp.LogisticsManager.handle(%Shipment{status: :ready})
      {:ok, %Shipment{status: :dispatched}}

  """

  def handle(%Shipment{status: :ready, carrier: carrier, tracking_number: nil} = shipment) do
    Logger.info("Dispatching shipment #{shipment.id} via carrier #{carrier}")

    case DispatchClient.book(carrier, build_dispatch_payload(shipment)) do
      {:ok, %{tracking_number: tracking, estimated_delivery: eta}} ->
        {:ok, updated} =
          Repo.update(
            Shipment.changeset(shipment, %{
              status: :dispatched,
              tracking_number: tracking,
              estimated_delivery_at: eta,
              dispatched_at: DateTime.utc_now()
            })
          )

        Logger.info("Shipment #{shipment.id} dispatched, tracking: #{tracking}")
        {:ok, updated}

      {:error, :carrier_unavailable} ->
        Logger.warn("Carrier #{carrier} unavailable for shipment #{shipment.id}")
        {:error, :carrier_unavailable}

      {:error, reason} ->
        Logger.error("Dispatch failed for #{shipment.id}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  def handle(
        %StockAdjustment{
          warehouse_id: warehouse_id,
          sku: sku,
          quantity_delta: delta,
          reason: reason
        } = adjustment
      )
      when is_integer(delta) do
    Logger.info(
      "Adjusting stock for SKU #{sku} at warehouse #{warehouse_id} by #{delta} (reason: #{reason})"
    )

    current_stock = InventoryLedger.get_stock(warehouse_id, sku)

    new_stock = current_stock + delta

    if new_stock < 0 do
      Logger.warn("Stock adjustment would result in negative stock for SKU #{sku}")
      {:error, :negative_stock}
    else
      with {:ok, _ledger_entry} <-
             InventoryLedger.record(warehouse_id, sku, delta, reason),
           {:ok, updated} <-
             Repo.update(
               StockAdjustment.changeset(adjustment, %{
                 applied_at: DateTime.utc_now(),
                 resulting_stock: new_stock,
                 status: :applied
               })
             ) do
        {:ok, updated}
      end
    end
  end

  def handle(%Route{status: :pending_optimization, stops: stops} = route)
      when length(stops) >= 2 do
    Logger.info("Optimizing route #{route.id} with #{length(stops)} stops")

    stop_coords =
      Enum.map(stops, fn stop -> {stop.latitude, stop.longitude} end)

    case OptimizerService.optimize(stop_coords, strategy: :shortest_path) do
      {:ok, %{ordered_stops: ordered, total_km: km, estimated_minutes: mins}} ->
        reordered_stops = reorder_stops(stops, ordered)

        {:ok, updated} =
          Repo.update(
            Route.changeset(route, %{
              stops: reordered_stops,
              total_distance_km: km,
              estimated_duration_minutes: mins,
              status: :optimized,
              optimized_at: DateTime.utc_now()
            })
          )

        Logger.info("Route #{route.id} optimized: #{km}km, ~#{mins} min")
        {:ok, updated}

      {:error, :unsolvable} ->
        Logger.warn("Route #{route.id} could not be optimized")
        {:error, :unsolvable}
    end
  end


  defp build_dispatch_payload(shipment) do
    %{
      sender: shipment.origin_address,
      recipient: shipment.destination_address,
      weight_kg: shipment.weight_kg,
      dimensions: shipment.dimensions,
      service_level: shipment.service_level
    }
  end

  defp reorder_stops(stops, ordered_indices) do
    Enum.map(ordered_indices, fn idx -> Enum.at(stops, idx) end)
  end
end
```
