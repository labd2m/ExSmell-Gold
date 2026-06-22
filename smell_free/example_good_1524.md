```elixir
defmodule Logistics.RouteOptimizer do
  @moduledoc """
  Computes optimized delivery routes for a fleet of vehicles given
  a set of delivery stops and vehicle capacity constraints.

  Uses a greedy nearest-neighbor heuristic as a baseline route,
  with optional 2-opt improvement passes for shorter total distance.
  """

  alias Logistics.Stop
  alias Logistics.Vehicle
  alias Logistics.Route

  @type coordinate :: {float(), float()}
  @type distance_km :: float()

  @doc """
  Builds an optimized route for the given vehicle and ordered list of stops.

  Returns `{:ok, route}` with the optimized stop order and total estimated
  distance, or `{:error, :no_stops}` if the stop list is empty.
  """
  @spec optimize(Vehicle.t(), [Stop.t()]) ::
          {:ok, Route.t()} | {:error, :no_stops | :exceeds_capacity}
  def optimize(%Vehicle{} = _vehicle, []) do
    {:error, :no_stops}
  end

  def optimize(%Vehicle{capacity_kg: cap} = vehicle, stops) when is_list(stops) do
    total_weight = Enum.sum(Enum.map(stops, & &1.weight_kg))

    if total_weight > cap do
      {:error, :exceeds_capacity}
    else
      ordered = nearest_neighbor(vehicle.depot_coordinates, stops)
      improved = two_opt(ordered)
      total_distance = compute_total_distance(vehicle.depot_coordinates, improved)

      route = %Route{
        vehicle_id: vehicle.id,
        stops: improved,
        total_distance_km: total_distance,
        estimated_duration_minutes: estimate_duration(total_distance)
      }

      {:ok, route}
    end
  end

  @spec nearest_neighbor(coordinate(), [Stop.t()]) :: [Stop.t()]
  defp nearest_neighbor(origin, stops) do
    Enum.reduce(1..length(stops), {origin, stops, []}, fn _, {current, remaining, ordered} ->
      nearest = Enum.min_by(remaining, &haversine(current, &1.coordinates))
      {nearest.coordinates, remaining -- [nearest], [nearest | ordered]}
    end)
    |> elem(2)
    |> Enum.reverse()
  end

  @spec two_opt([Stop.t()]) :: [Stop.t()]
  defp two_opt(stops) when length(stops) < 4, do: stops

  defp two_opt(stops) do
    indices = Enum.to_list(0..(length(stops) - 1))
    pairs = for i <- indices, j <- indices, j > i + 1, do: {i, j}

    Enum.reduce_while(pairs, stops, fn {i, j}, current ->
      candidate = two_opt_swap(current, i, j)

      if route_distance(candidate) < route_distance(current) do
        {:halt, candidate}
      else
        {:cont, current}
      end
    end)
  end

  @spec two_opt_swap([Stop.t()], non_neg_integer(), non_neg_integer()) :: [Stop.t()]
  defp two_opt_swap(stops, i, j) do
    prefix = Enum.take(stops, i)
    middle = stops |> Enum.drop(i) |> Enum.take(j - i + 1) |> Enum.reverse()
    suffix = Enum.drop(stops, j + 1)
    prefix ++ middle ++ suffix
  end

  @spec route_distance([Stop.t()]) :: distance_km()
  defp route_distance([]), do: 0.0

  defp route_distance([_single]), do: 0.0

  defp route_distance(stops) do
    stops
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.reduce(0.0, fn [a, b], acc -> acc + haversine(a.coordinates, b.coordinates) end)
  end

  @spec compute_total_distance(coordinate(), [Stop.t()]) :: distance_km()
  defp compute_total_distance(origin, []), do: 0.0

  defp compute_total_distance(origin, [first | _] = stops) do
    leg_to_first = haversine(origin, first.coordinates)
    leg_to_first + route_distance(stops)
  end

  @earth_radius_km 6_371.0

  @spec haversine(coordinate(), coordinate()) :: distance_km()
  defp haversine({lat1, lon1}, {lat2, lon2}) do
    dlat = :math.pi() / 180 * (lat2 - lat1)
    dlon = :math.pi() / 180 * (lon2 - lon1)
    a =
      :math.sin(dlat / 2) ** 2 +
        :math.cos(:math.pi() / 180 * lat1) *
          :math.cos(:math.pi() / 180 * lat2) *
          :math.sin(dlon / 2) ** 2

    Float.round(2 * @earth_radius_km * :math.atan2(:math.sqrt(a), :math.sqrt(1 - a)), 4)
  end

  @spec estimate_duration(distance_km()) :: pos_integer()
  defp estimate_duration(distance_km) do
    round(distance_km / 50.0 * 60)
  end
end
```
