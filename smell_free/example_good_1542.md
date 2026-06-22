```elixir
defmodule Logistics.RouteOptimizer do
  @moduledoc """
  Nearest-neighbor heuristic route optimizer for delivery stop sequencing.

  Accepts a depot origin and a list of delivery stops with coordinates,
  and returns a sequenced route that minimizes total estimated travel distance.
  All distance calculations use the Haversine formula for spherical geodesics.
  """

  @type coordinates :: %{lat: float(), lng: float()}
  @type stop :: %{id: String.t(), label: String.t(), coordinates: coordinates()}
  @type route :: [stop()]

  @earth_radius_km 6_371.0

  @doc """
  Computes an optimized delivery route from the depot through all stops.

  Returns the list of stops in visit order. The depot is not included in the
  returned list but is used as the starting reference point.
  """
  @spec optimize(coordinates(), [stop()]) :: {:ok, route()} | {:error, :no_stops}
  def optimize(_depot, []), do: {:error, :no_stops}

  def optimize(depot, stops) when is_map(depot) and is_list(stops) do
    ordered = nearest_neighbor_sequence(depot, stops)
    {:ok, ordered}
  end

  @doc """
  Calculates the total geodesic distance in kilometers for a given stop sequence.

  Includes the leg from the depot to the first stop.
  """
  @spec total_distance(coordinates(), route()) :: float()
  def total_distance(_depot, []), do: 0.0

  def total_distance(depot, [first | rest]) do
    initial_leg = haversine(depot, first.coordinates)

    rest
    |> Enum.zip([first | rest])
    |> Enum.reduce(initial_leg, fn {current, previous}, acc ->
      acc + haversine(previous.coordinates, current.coordinates)
    end)
  end

  defp nearest_neighbor_sequence(origin, stops) do
    do_nearest_neighbor(origin, stops, [])
  end

  defp do_nearest_neighbor(_current, [], visited), do: Enum.reverse(visited)

  defp do_nearest_neighbor(current, remaining, visited) do
    nearest = find_nearest(current, remaining)
    updated_remaining = List.delete(remaining, nearest)
    do_nearest_neighbor(nearest.coordinates, updated_remaining, [nearest | visited])
  end

  defp find_nearest(origin, stops) do
    Enum.min_by(stops, fn stop -> haversine(origin, stop.coordinates) end)
  end

  defp haversine(%{lat: lat1, lng: lng1}, %{lat: lat2, lng: lng2}) do
    dlat = to_radians(lat2 - lat1)
    dlng = to_radians(lng2 - lng1)

    a =
      :math.sin(dlat / 2) ** 2 +
        :math.cos(to_radians(lat1)) *
          :math.cos(to_radians(lat2)) *
          :math.sin(dlng / 2) ** 2

    c = 2 * :math.atan2(:math.sqrt(a), :math.sqrt(1 - a))
    @earth_radius_km * c
  end

  defp to_radians(degrees), do: degrees * :math.pi() / 180.0
end
```
