```elixir
defmodule Logistics.ShipmentRouter do
  @moduledoc """
  Routes shipments to the appropriate carrier lane based on
  shipment status, weight class, and destination constraints.
  """

  alias Logistics.{Shipment, CarrierAPI, TrackingService, RoutingLog}

  @express_weight_limit 5.0
  @freight_weight_threshold 50.0


  def route_shipment(%Shipment{
        status: :pending,
        weight_kg: weight_kg,
        destination: destination,
        tracking_id: tracking_id,
        carrier: carrier,
        scheduled_at: scheduled_at
      })
      when weight_kg <= @express_weight_limit do
    lane = CarrierAPI.assign_lane(carrier, :express, destination)

    TrackingService.emit_event(tracking_id, :routed_express, %{
      lane: lane,
      scheduled_at: scheduled_at,
      destination: destination
    })

    RoutingLog.write(tracking_id, :express, weight_kg)
    {:ok, :express, lane}
  end

  def route_shipment(%Shipment{
        status: :pending,
        weight_kg: weight_kg,
        destination: destination,
        tracking_id: tracking_id,
        carrier: carrier,
        scheduled_at: scheduled_at
      })
      when weight_kg > @express_weight_limit and weight_kg <= @freight_weight_threshold do
    lane = CarrierAPI.assign_lane(carrier, :standard, destination)

    TrackingService.emit_event(tracking_id, :routed_standard, %{
      lane: lane,
      scheduled_at: scheduled_at,
      destination: destination
    })

    RoutingLog.write(tracking_id, :standard, weight_kg)
    {:ok, :standard, lane}
  end

  def route_shipment(%Shipment{
        status: :pending,
        weight_kg: weight_kg,
        destination: destination,
        tracking_id: tracking_id,
        carrier: carrier,
        scheduled_at: scheduled_at
      })
      when weight_kg > @freight_weight_threshold do
    lane = CarrierAPI.assign_lane(carrier, :freight, destination)

    TrackingService.emit_event(tracking_id, :routed_freight, %{
      lane: lane,
      scheduled_at: scheduled_at,
      destination: destination
    })

    RoutingLog.write(tracking_id, :freight, weight_kg)
    {:ok, :freight, lane}
  end

  def route_shipment(%Shipment{
        status: :in_transit,
        weight_kg: _weight_kg,
        destination: destination,
        tracking_id: tracking_id,
        carrier: carrier,
        scheduled_at: scheduled_at
      }) do
    current = TrackingService.current_location(tracking_id)

    Logger.info(
      "[#{tracking_id}] Already in transit via #{carrier} to #{destination}. " <>
        "ETA: #{scheduled_at}. Current: #{current}"
    )

    {:error, :already_routed}
  end

  def route_shipment(%Shipment{
        status: :delivered,
        weight_kg: _weight_kg,
        destination: destination,
        tracking_id: tracking_id,
        carrier: _carrier,
        scheduled_at: _scheduled_at
      }) do
    Logger.warning("[#{tracking_id}] Attempted re-routing of delivered shipment to #{destination}")
    {:error, :already_delivered}
  end


  def route_shipment(%Shipment{status: status}) do
    {:error, {:unsupported_status, status}}
  end
end
```
