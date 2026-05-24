```elixir
defmodule Logistics.ShipmentDispatcher do
  @moduledoc """
  Responsible for assigning carriers to outbound shipments and
  dispatching pick-up notifications to drivers.
  """

  require Logger

  alias Logistics.{Shipment, TrackingEvent, Manifest}
  alias Carriers.{Carrier, ServiceLevel, Route}
  alias Fleet.{Vehicle, Driver}

  @max_weight_kg 1_000

  def create_shipment(order_id, origin, destination, weight_kg) do
    cond do
      weight_kg <= 0 ->
        {:error, :invalid_weight}

      weight_kg > @max_weight_kg ->
        {:error, :weight_exceeds_limit}

      true ->
        shipment = %Shipment{
          order_id:    order_id,
          origin:      origin,
          destination: destination,
          weight_kg:   weight_kg,
          status:      :awaiting_dispatch,
          created_at:  DateTime.utc_now()
        }

        Shipment.persist(shipment)
    end
  end

  def dispatch(%Shipment{} = shipment, carrier_code) do
    carrier = Carrier.find(carrier_code)

    if carrier.active != true do
      {:error, :carrier_not_active}
    else
      service = Carrier.preferred_service_level(carrier)

      cond do
        service.availability != :open ->
          {:error, :service_level_unavailable}

        Time.compare(Time.utc_now(), service.cutoff_time) == :gt ->
          {:error, :past_cutoff_time}

        true ->
          route   = ServiceLevel.select_route(service, shipment.origin, shipment.destination)
          vehicle = Route.assigned_vehicle(route)

          if vehicle.capacity_kg < shipment.weight_kg do
            {:error, :vehicle_capacity_exceeded}
          else
            manifest = %Manifest{
              shipment_id:   shipment.id,
              carrier_code:  carrier_code,
              route_id:      route.id,
              vehicle_id:    vehicle.id,
              dispatched_at: DateTime.utc_now()
            }

            with {:ok, saved_manifest} <- Manifest.persist(manifest),
                 :ok                   <- Driver.notify(vehicle.driver_id, saved_manifest),
                 {:ok, _event}         <- TrackingEvent.record(shipment.id, :dispatched) do
              Shipment.persist(%{shipment | status: :dispatched, manifest_id: saved_manifest.id})
            end
          end
      end
    end
  end

  def cancel_dispatch(%Shipment{status: :dispatched} = shipment, reason) do
    with {:ok, _event}  <- TrackingEvent.record(shipment.id, :cancelled, reason),
         {:ok, updated} <- Shipment.persist(%{shipment | status: :cancelled, cancel_reason: reason}) do
      Logger.info("Shipment #{shipment.id} cancelled: #{reason}")
      {:ok, updated}
    end
  end

  def cancel_dispatch(%Shipment{status: status}, _reason),
    do: {:error, "Cannot cancel shipment in #{status} state"}

  def track(shipment_id) do
    TrackingEvent.list(shipment_id)
  end

  def reroute(%Shipment{status: :dispatched} = shipment, new_destination) do
    Shipment.persist(%{shipment | destination: new_destination, rerouted_at: DateTime.utc_now()})
  end

  def reroute(%Shipment{}, _new_destination), do: {:error, :cannot_reroute}

  def list_by_carrier(carrier_code, opts \\ []) do
    status = Keyword.get(opts, :status)
    Shipment.list(carrier_code: carrier_code, status: status)
  end

  def estimated_delivery(%Shipment{manifest_id: nil}), do: {:error, :not_dispatched}

  def estimated_delivery(%Shipment{manifest_id: manifest_id}) do
    manifest = Manifest.find(manifest_id)
    Route.estimated_arrival(manifest.route_id)
  end
end
```
