```elixir
defmodule Logistics.RouteOptimiser do
  @moduledoc """
  Computes an optimised delivery route through a set of waypoints using a
  greedy nearest-neighbour heuristic. The module is entirely stateless and
  pure; it performs no IO and holds no process state, making it trivially
  testable and safe to call from any context.
  """

  @type coords :: {float(), float()}
  @type waypoint :: %{id: String.t(), lat: float(), lng: float()}
  @type route :: [waypoint()]
  @type route_result :: {:ok, route(), float()} | {:error, :no_waypoints}

  @earth_radius_km 6_371.0

  @doc """
  Returns an ordered route visiting all `waypoints` starting from `origin`,
  using nearest-neighbour selection at each step. Also returns the total
  estimated distance in kilometres.
  """
  @spec optimise(waypoint(), [waypoint()]) :: route_result()
  def optimise(_origin, []), do: {:error, :no_waypoints}

  def optimise(%{lat: _, lng: _} = origin, waypoints) when is_list(waypoints) do
    {route, distance} = greedy_route(origin, waypoints, [], 0.0)
    {:ok, route, Float.round(distance, 2)}
  end

  @doc "Returns the haversine distance in kilometres between two waypoints."
  @spec distance_km(waypoint(), waypoint()) :: float()
  def distance_km(%{lat: lat1, lng: lng1}, %{lat: lat2, lng: lng2}) do
    haversine(lat1, lng1, lat2, lng2)
  end

  @doc "Returns the total distance of a pre-ordered route in kilometres."
  @spec total_distance_km([waypoint()]) :: float()
  def total_distance_km([]), do: 0.0
  def total_distance_km([_single]), do: 0.0

  def total_distance_km(waypoints) when is_list(waypoints) do
    waypoints
    |> Enum.zip(tl(waypoints))
    |> Enum.reduce(0.0, fn {a, b}, acc -> acc + distance_km(a, b) end)
    |> Float.round(2)
  end

  defp greedy_route(_current, [], route, dist) do
    {Enum.reverse(route), dist}
  end

  defp greedy_route(current, remaining, route, dist) do
    nearest = Enum.min_by(remaining, fn wp -> haversine(current.lat, current.lng, wp.lat, wp.lng) end)
    leg_dist = haversine(current.lat, current.lng, nearest.lat, nearest.lng)
    rest = List.delete(remaining, nearest)
    greedy_route(nearest, rest, [nearest | route], dist + leg_dist)
  end

  defp haversine(lat1, lng1, lat2, lng2) do
    dlat = to_rad(lat2 - lat1)
    dlng = to_rad(lng2 - lng1)
    a =
      :math.sin(dlat / 2) ** 2 +
        :math.cos(to_rad(lat1)) * :math.cos(to_rad(lat2)) * :math.sin(dlng / 2) ** 2
    @earth_radius_km * 2 * :math.atan2(:math.sqrt(a), :math.sqrt(1 - a))
  end

  defp to_rad(deg), do: deg * :math.pi() / 180.0
end
```
