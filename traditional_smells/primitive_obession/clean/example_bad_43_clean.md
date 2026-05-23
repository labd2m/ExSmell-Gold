```elixir
defmodule Logistics.RouteOptimizer do
  @moduledoc """
  Optimises delivery routes for a fleet of vehicles by calculating
  distances between stops and selecting the nearest depot.
  """

  require Logger

  @earth_radius_km 6_371.0
  @max_route_distance_km 500.0

  @depots [
    %{id: "DEP-01", name: "North Hub", lat: -19.9167, lon: -43.9345},
    %{id: "DEP-02", name: "South Hub", lat: -23.5505, lon: -46.6333},
    %{id: "DEP-03", name: "West Hub",  lat: -15.7797, lon: -47.9297}
  ]

  @spec calculate_distance(float(), float(), float(), float()) :: float()
  def calculate_distance(lat1, lon1, lat2, lon2)
      when is_float(lat1) and is_float(lon1) and is_float(lat2) and is_float(lon2) do
    dlat = deg_to_rad(lat2 - lat1)
    dlon = deg_to_rad(lon2 - lon1)

    a =
      :math.sin(dlat / 2) * :math.sin(dlat / 2) +
        :math.cos(deg_to_rad(lat1)) * :math.cos(deg_to_rad(lat2)) *
          :math.sin(dlon / 2) * :math.sin(dlon / 2)

    c = 2 * :math.atan2(:math.sqrt(a), :math.sqrt(1 - a))
    @earth_radius_km * c
  end

  @spec find_nearest_depot(float(), float(), String.t()) ::
          {:ok, map()} | {:error, String.t()}
  def find_nearest_depot(lat, lon, vehicle_type)
      when is_float(lat) and is_float(lon) and is_binary(vehicle_type) do
    with :ok <- validate_coordinates(lat, lon) do
      nearest =
        @depots
        |> Enum.map(fn depot ->
          dist = calculate_distance(lat, lon, depot.lat, depot.lon)
          Map.put(depot, :distance_km, dist)
        end)
        |> Enum.filter(fn d -> d.distance_km <= @max_route_distance_km end)
        |> Enum.min_by(& &1.distance_km, fn -> nil end)

      case nearest do
        nil -> {:error, "no_depot_within_range"}
        depot -> {:ok, depot}
      end
    end
  end

  @spec build_waypoint(float(), float(), map()) :: map()
  def build_waypoint(lat, lon, metadata)
      when is_float(lat) and is_float(lon) and is_map(metadata) do
    %{
      lat: lat,
      lon: lon,
      label: Map.get(metadata, :label, "unknown"),
      arrival_window: Map.get(metadata, :arrival_window),
      priority: Map.get(metadata, :priority, :normal),
      inserted_at: DateTime.utc_now()
    }
  end

  @spec estimate_route(list(map()), String.t()) ::
          {:ok, map()} | {:error, String.t()}
  def estimate_route(stops, vehicle_id) when is_list(stops) and is_binary(vehicle_id) do
    if length(stops) < 2 do
      {:error, "insufficient_stops"}
    else
      total_km =
        stops
        |> Enum.chunk_every(2, 1, :discard)
        |> Enum.reduce(0.0, fn [a, b], acc ->
          acc + calculate_distance(a.lat, a.lon, b.lat, b.lon)
        end)

      avg_speed_kmh = 60.0
      estimated_hours = total_km / avg_speed_kmh

      result = %{
        vehicle_id: vehicle_id,
        stop_count: length(stops),
        total_distance_km: Float.round(total_km, 2),
        estimated_duration_hours: Float.round(estimated_hours, 2),
        feasible: total_km <= @max_route_distance_km
      }

      Logger.info("Route estimated for #{vehicle_id}: #{total_km} km")
      {:ok, result}
    end
  end

  defp validate_coordinates(lat, lon) do
    cond do
      lat < -90.0 or lat > 90.0 -> {:error, "latitude_out_of_range"}
      lon < -180.0 or lon > 180.0 -> {:error, "longitude_out_of_range"}
      true -> :ok
    end
  end

  defp deg_to_rad(deg), do: deg * :math.pi() / 180.0
end
```
