```elixir
defmodule Fulfillment.DeliveryStop do
  @moduledoc "Represents a single stop on a delivery route."

  defstruct [
    :id,
    :route_id,
    :address,
    :lat,
    :lng,
    :depot_lat,
    :depot_lng,
    :time_window_start,
    :time_window_end,
    :package_count,
    :total_weight_kg,
    :requires_liftgate,
    :stop_sequence,
    :estimated_arrival
  ]

  def get!(id) do
    %__MODULE__{
      id: id,
      route_id: "RT-2024-042",
      address: "123 Main St, Springfield",
      lat: 39.7817,
      lng: -89.6501,
      depot_lat: 39.8003,
      depot_lng: -89.6440,
      time_window_start: ~T[09:00:00],
      time_window_end: ~T[12:00:00],
      package_count: 3,
      total_weight_kg: 42.5,
      requires_liftgate: true,
      stop_sequence: 4,
      estimated_arrival: ~T[10:30:00]
    }
  end

  def distance_km(%__MODULE__{lat: lat, lng: lng, depot_lat: dlat, depot_lng: dlng}) do
    dx = (lat - dlat) * 111.0
    dy = (lng - dlng) * 111.0 * :math.cos(lat * :math.pi() / 180)
    Float.round(:math.sqrt(dx * dx + dy * dy), 2)
  end

  def requires_equipment?(%__MODULE__{requires_liftgate: true}), do: true
  def requires_equipment?(_), do: false

  def time_window_penalty(%__MODULE__{time_window_start: wstart, time_window_end: wend, estimated_arrival: arrival}) do
    window_minutes = Time.diff(wend, wstart) |> div(60)
    if Time.compare(arrival, wend) == :gt or Time.compare(arrival, wstart) == :lt do
      max(0, 60 - window_minutes)
    else
      0
    end
  end

  def package_weight_kg(%__MODULE__{total_weight_kg: w}), do: w

  def stop_label(%__MODULE__{stop_sequence: seq, address: addr}) do
    "Stop ##{seq}: #{addr}"
  end
end

defmodule Fulfillment.RouteBuilder do
  @moduledoc """
  Builds optimised delivery routes and computes logistics costs
  for each stop based on distance, weight, and time constraints.
  """

  alias Fulfillment.DeliveryStop
  require Logger

  @cost_per_km        2.50
  @equipment_surcharge 35.00
  @weight_rate_per_kg  0.15
  @penalty_rate        1.20

  @doc """
  Estimates the total cost for a list of stop IDs and returns a
  route cost summary.
  """
  def compute_route_cost(stop_ids) do
    stop_costs =
      Enum.map(stop_ids, fn id ->
        stop = DeliveryStop.get!(id)
        cost = estimate_stop_cost(id)
        Logger.debug("Stop #{id} (#{DeliveryStop.stop_label(stop)}): #{cost}")
        {id, cost}
      end)

    total = stop_costs |> Enum.map(&elem(&1, 1)) |> Enum.sum()

    %{
      stops:         Map.new(stop_costs),
      total_cost:    Float.round(total, 2),
      stop_count:    length(stop_ids),
      estimated_at:  DateTime.utc_now()
    }
  end

  defp estimate_stop_cost(stop_id) do
    stop      = DeliveryStop.get!(stop_id)
    distance  = DeliveryStop.distance_km(stop)
    equipment = DeliveryStop.requires_equipment?(stop)
    penalty   = DeliveryStop.time_window_penalty(stop)
    weight    = DeliveryStop.package_weight_kg(stop)

    distance_cost  = distance * @cost_per_km
    equipment_cost = if equipment, do: @equipment_surcharge, else: 0.0
    weight_cost    = weight * @weight_rate_per_kg
    penalty_cost   = penalty * @penalty_rate

    distance_cost + equipment_cost + weight_cost + penalty_cost
  end
end
```
