# Annotated Example — Long Function

## Metadata

- **Smell name:** Long Function
- **Expected smell location:** `Logistics.CrossDockPlanner.plan_transfer/3`
- **Affected function(s):** `plan_transfer/3`
- **Short explanation:** The `plan_transfer/3` function handles inbound shipment validation, available dock-door scheduling, load-capacity verification, transfer manifest line construction, vehicle assignment, outbound leg creation, manifest persistence, driver briefing dispatch, and event publication — all in one function body. Every step is operationally distinct and long enough to live in its own private helper.

---

```elixir
defmodule Logistics.CrossDockPlanner do
  @moduledoc """
  Plans cross-dock transfers between inbound and outbound shipments,
  assigning dock doors, vehicles, and drivers for same-day consolidation.
  """

  alias Logistics.{
    InboundShipment, DockDoor, Vehicle, Driver,
    TransferManifest, ManifestLine, OutboundLeg, Repo, EventBus
  }
  alias Notifications.Dispatcher
  require Logger

  @max_door_utilisation_pct 0.90
  @transfer_window_hours 4
  @min_transfer_weight_kg 10.0

  # VALIDATION: SMELL START - Long Function
  # VALIDATION: This is a smell because `plan_transfer/3` combines inbound shipment
  # VALIDATION: validation, dock-door availability querying, capacity checking,
  # VALIDATION: manifest line building, vehicle selection, outbound leg creation,
  # VALIDATION: manifest persistence, driver notification, and event publishing
  # VALIDATION: inside a single function that is far too long and too broad in scope.
  def plan_transfer(warehouse_id, inbound_shipment_id, outbound_destination) do
    Logger.info("Planning cross-dock transfer warehouse=#{warehouse_id} inbound=#{inbound_shipment_id}")

    # --- Load inbound shipment ---
    case Repo.get(InboundShipment, inbound_shipment_id) |> Repo.preload(:items) do
      nil ->
        {:error, :inbound_shipment_not_found}

      %InboundShipment{status: status} when status not in [:arrived, :unloading] ->
        {:error, {:shipment_not_ready, status}}

      %InboundShipment{} = inbound ->
        # --- Filter items destined for outbound location ---
        transfer_items =
          Enum.filter(inbound.items, fn item ->
            item.destination == outbound_destination and item.status == :pending_transfer
          end)

        if Enum.empty?(transfer_items) do
          {:error, :no_items_for_destination}
        else
          total_weight_kg =
            Enum.reduce(transfer_items, 0.0, fn i, acc -> acc + i.weight_kg * i.quantity end)

          total_volume_m3 =
            Enum.reduce(transfer_items, 0.0, fn i, acc -> acc + i.volume_m3 * i.quantity end)

          if total_weight_kg < @min_transfer_weight_kg do
            {:error, {:transfer_too_light, total_weight_kg}}
          else
            # --- Find available dock door ---
            transfer_start = DateTime.utc_now()
            transfer_end   = DateTime.add(transfer_start, @transfer_window_hours * 3600, :second)

            available_doors =
              DockDoor
              |> DockDoor.for_warehouse(warehouse_id)
              |> DockDoor.outbound()
              |> DockDoor.available_between(transfer_start, transfer_end)
              |> DockDoor.order_by_utilisation(:asc)
              |> Repo.all()

            door =
              Enum.find(available_doors, fn d ->
                d.current_utilisation_pct < @max_door_utilisation_pct
              end)

            if is_nil(door) do
              {:error, :no_dock_door_available}
            else
              # --- Select vehicle with sufficient capacity ---
              vehicle =
                Vehicle
                |> Vehicle.for_warehouse(warehouse_id)
                |> Vehicle.available_at(transfer_start)
                |> Vehicle.with_capacity(total_weight_kg, total_volume_m3)
                |> Vehicle.order_by_capacity(:asc)
                |> Repo.first()

              if is_nil(vehicle) do
                {:error, :no_vehicle_available}
              else
                # --- Select available driver ---
                driver =
                  Driver
                  |> Driver.for_warehouse(warehouse_id)
                  |> Driver.available_at(transfer_start)
                  |> Repo.first()

                if is_nil(driver) do
                  {:error, :no_driver_available}
                else
                  # --- Build manifest lines ---
                  manifest_lines_attrs =
                    Enum.map(transfer_items, fn item ->
                      %{
                        sku: item.sku,
                        description: item.description,
                        quantity: item.quantity,
                        weight_kg: item.weight_kg,
                        volume_m3: item.volume_m3,
                        lot_number: item.lot_number
                      }
                    end)

                  # --- Create manifest ---
                  {:ok, manifest} =
                    Repo.insert(TransferManifest.changeset(%TransferManifest{}, %{
                      warehouse_id: warehouse_id,
                      inbound_shipment_id: inbound_shipment_id,
                      outbound_destination: outbound_destination,
                      dock_door_id: door.id,
                      vehicle_id: vehicle.id,
                      driver_id: driver.id,
                      total_weight_kg: total_weight_kg,
                      total_volume_m3: total_volume_m3,
                      scheduled_start: transfer_start,
                      scheduled_end: transfer_end,
                      status: :planned
                    }))

                  Enum.each(manifest_lines_attrs, fn attrs ->
                    Repo.insert!(%ManifestLine{
                      transfer_manifest_id: manifest.id,
                      sku: attrs.sku,
                      description: attrs.description,
                      quantity: attrs.quantity,
                      weight_kg: attrs.weight_kg,
                      volume_m3: attrs.volume_m3,
                      lot_number: attrs.lot_number
                    })
                  end)

                  # --- Create outbound leg record ---
                  {:ok, _leg} =
                    Repo.insert(%OutboundLeg{
                      manifest_id: manifest.id,
                      destination: outbound_destination,
                      vehicle_id: vehicle.id,
                      departure_at: transfer_end,
                      status: :scheduled
                    })

                  # --- Notify driver ---
                  Dispatcher.dispatch(driver.user_id, %{
                    type: "transfer_assignment",
                    payload: %{
                      manifest_id: manifest.id,
                      dock_door: door.code,
                      vehicle_plate: vehicle.plate_number,
                      scheduled_start: transfer_start,
                      destination: outbound_destination,
                      item_count: length(transfer_items)
                    }
                  })

                  # --- Publish event ---
                  EventBus.publish("cross_dock.planned", %{
                    manifest_id: manifest.id,
                    warehouse_id: warehouse_id,
                    inbound_shipment_id: inbound_shipment_id,
                    destination: outbound_destination
                  })

                  Logger.info("Cross-dock manifest #{manifest.id} planned for warehouse #{warehouse_id}")
                  {:ok, manifest}
                end
              end
            end
          end
        end
    end
  end
  # VALIDATION: SMELL END

  def confirm_departure(manifest_id) do
    case Repo.get(TransferManifest, manifest_id) do
      nil -> {:error, :not_found}
      m ->
        m
        |> TransferManifest.changeset(%{status: :departed, departed_at: DateTime.utc_now()})
        |> Repo.update()
    end
  end
end
```
