# example_bad_7_clean

```elixir
defmodule Logistics.ShipmentScheduler do
  @moduledoc """
  Coordinates shipment creation, carrier assignment, and route optimization
  for outbound logistics operations.
  """

  alias Logistics.RouteOptimizer
  alias Logistics.CarrierRegistry
  alias Logistics.TrackingService

  @max_weight_kg 1_000
  @default_priority :standard

  def schedule_shipment(shipment_params, operator_id) do
    with {:ok, origin} <- resolve_location(shipment_params["origin_code"]),
         {:ok, destination} <- resolve_location(shipment_params["destination_code"]),
         {:ok, carrier} <- select_carrier(shipment_params, origin, destination),
         {:ok, request} <- build_shipment_request(shipment_params, carrier, operator_id),
         {:ok, route} <- RouteOptimizer.find_route(origin, destination, request),
         {:ok, tracking_id} <- TrackingService.register(route, carrier) do
      {:ok, %{tracking_id: tracking_id, carrier: carrier.name, route_summary: route.summary}}
    end
  end

  defp resolve_location(code) when is_binary(code) do
    {:ok, %{code: code, lat: -19.9167, lng: -43.9345, region: :southeast}}
  end
  defp resolve_location(_), do: {:error, :invalid_location_code}

  defp select_carrier(params, origin, destination) do
    weight_kg = Map.get(params, "weight_kg", 0)
    priority = Map.get(params, "priority", @default_priority)
    CarrierRegistry.best_match(origin, destination, weight_kg, priority)
  end

  defp build_shipment_request(shipment_params, carrier, operator_id) do
    delivery_window = Map.get(shipment_params, "delivery_window_hours")

    request = %{
      operator_id: operator_id,
      carrier_id: carrier.id,
      weight_kg: Map.get(shipment_params, "weight_kg", 0),
      volume_m3: Map.get(shipment_params, "volume_m3", 0.0),
      delivery_window_hours: delivery_window,
      priority: Map.get(shipment_params, "priority", @default_priority),
      fragile: Map.get(shipment_params, "fragile", false),
      notes: Map.get(shipment_params, "notes", ""),
      scheduled_at: DateTime.utc_now()
    }

    {:ok, request}
  end

  defp validate_weight(weight_kg) when is_number(weight_kg) and weight_kg > 0 and weight_kg <= @max_weight_kg,
    do: :ok
  defp validate_weight(_), do: {:error, :invalid_weight}
end
```
