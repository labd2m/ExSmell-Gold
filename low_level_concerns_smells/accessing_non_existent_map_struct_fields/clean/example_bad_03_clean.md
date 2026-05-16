```elixir
defmodule Logistics.RouteOptimizer do
  @moduledoc """
  Computes optimal delivery routes and estimates operational costs
  for the freight dispatch system.
  """

  @avg_fuel_consumption_per_100km 28.5  # liters, fully-loaded truck
  @driver_cost_per_hour 42.0
  @average_speed_kmh 75.0

  @doc """
  Returns the cheapest route between two depot codes given a list of
  candidate route segments and current operational parameters.
  """
  def optimize(from_depot, to_depot, candidate_routes, params) do
    candidate_routes
    |> Enum.filter(&valid_route?(&1, from_depot, to_depot))
    |> Enum.map(fn route ->
      cost = estimate_cost(route, params)
      {route, cost}
    end)
    |> Enum.min_by(fn {_route, cost} -> cost end)
  end

  @doc """
  Estimates the total operational cost for a single route segment map.

  `route` is expected to have:
    - `:distance_km`    — total route distance in kilometres
    - `:waypoints`      — ordered list of stop identifiers

  `params` is expected to have:
    - `:fuel_price_per_liter` — current fuel price
    - `:cargo_weight_kg`      — total cargo weight
    - `:toll_total`           — sum of tolls along the route
  """
  def estimate_cost(route, params) do
    distance_km = Map.fetch!(route, :distance_km)

    fuel_price  = params[:fuel_price_per_liter]
    cargo_kg    = params[:cargo_weight_kg]
    toll_total  = params[:toll_total]

    weight_factor = 1.0 + cargo_kg / 10_000.0
    adjusted_consumption = @avg_fuel_consumption_per_100km * weight_factor

    fuel_liters = distance_km * (adjusted_consumption / 100.0)
    fuel_cost   = Float.round(fuel_liters * fuel_price, 2)

    travel_hours = distance_km / @average_speed_kmh
    driver_cost  = Float.round(travel_hours * @driver_cost_per_hour, 2)

    total = Float.round(fuel_cost + driver_cost + toll_total, 2)

    %{
      fuel_cost:   fuel_cost,
      driver_cost: driver_cost,
      toll_cost:   toll_total,
      total:       total
    }
  end

  @doc """
  Returns a human-readable summary of the chosen route and its cost breakdown.
  """
  def format_result({route, cost_breakdown}) do
    waypoints = Enum.join(route.waypoints, " → ")

    """
    Route   : #{waypoints}
    Distance: #{route.distance_km} km
    Fuel    : $#{cost_breakdown.fuel_cost}
    Driver  : $#{cost_breakdown.driver_cost}
    Tolls   : $#{cost_breakdown.toll_cost}
    --------------------------
    TOTAL   : $#{cost_breakdown.total}
    """
  end

  ## Private

  defp valid_route?(%{from: from, to: to}, from, to), do: true
  defp valid_route?(_, _, _), do: false
end
```
