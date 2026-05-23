# Annotated Example: Primitive Obsession

## Metadata

- **Smell Name**: Primitive Obsession
- **Expected Smell Location**: `haversine_distance/4`, `nearest_depot/2`, `assign_delivery_zone/2`, `within_radius?/5`
- **Affected Function(s)**: All public functions in `Logistics.GeoRouter`
- **Explanation**: Geographic coordinates are represented as two separate `float()` values (`latitude` and `longitude`) passed individually to every function rather than being wrapped in a `%Coordinate{}` struct. This forces callers to always manage two related values, makes argument-order mistakes (lat/lng vs lng/lat) undetectable at compile time, and prevents attaching domain behaviour (e.g., validation, projection) to the type.

## Code

```elixir
defmodule Logistics.GeoRouter do
  @moduledoc """
  Provides geographic routing utilities for the delivery network:
  distance calculations, zone assignment, and nearest-depot lookup.
  Uses the Haversine formula for great-circle distance approximation.
  """

  require Logger

  @earth_radius_km 6_371.0

  @delivery_zones [
    %{id: "ZONE_A", name: "Downtown Core", lat: 37.7749, lng: -122.4194, radius_km: 5.0},
    %{id: "ZONE_B", name: "East Bay", lat: 37.8044, lng: -122.2712, radius_km: 8.0},
    %{id: "ZONE_C", name: "Peninsula", lat: 37.5630, lng: -122.0530, radius_km: 12.0},
    %{id: "ZONE_D", name: "North Bay", lat: 38.0799, lng: -122.2477, radius_km: 15.0}
  ]

  @depots [
    %{id: "DEPOT_01", name: "SFO Warehouse", lat: 37.6213, lng: -122.3790},
    %{id: "DEPOT_02", name: "Oakland Hub", lat: 37.7214, lng: -122.2208},
    %{id: "DEPOT_03", name: "San Jose Center", lat: 37.3382, lng: -121.8863}
  ]

  # VALIDATION: SMELL START - Primitive Obsession
  # VALIDATION: This is a smell because a geographic coordinate is modelled as two
  # VALIDATION: raw `float()` values (`lat1`, `lng1`, `lat2`, `lng2`) instead of a
  # VALIDATION: `%Coordinate{latitude: float(), longitude: float()}` struct.
  # VALIDATION: Every function takes four floats and callers can silently swap
  # VALIDATION: latitude and longitude with no compile-time protection.
  @spec haversine_distance(float(), float(), float(), float()) :: float()
  def haversine_distance(lat1, lng1, lat2, lng2) do
    dlat = to_rad(lat2 - lat1)
    dlng = to_rad(lng2 - lng1)

    a =
      :math.sin(dlat / 2) * :math.sin(dlat / 2) +
        :math.cos(to_rad(lat1)) * :math.cos(to_rad(lat2)) *
          :math.sin(dlng / 2) * :math.sin(dlng / 2)

    c = 2 * :math.atan2(:math.sqrt(a), :math.sqrt(1 - a))
    Float.round(@earth_radius_km * c, 3)
  end

  @spec nearest_depot(float(), float()) :: {:ok, map()} | {:error, String.t()}
  def nearest_depot(lat, lng) do
    case @depots do
      [] ->
        {:error, "No depots configured"}

      depots ->
        nearest =
          Enum.min_by(depots, fn depot ->
            haversine_distance(lat, lng, depot.lat, depot.lng)
          end)

        distance = haversine_distance(lat, lng, nearest.lat, nearest.lng)

        Logger.debug(
          "Nearest depot to (#{lat}, #{lng}): #{nearest.name} at #{distance} km"
        )

        {:ok, Map.put(nearest, :distance_km, distance)}
    end
  end

  @spec assign_delivery_zone(float(), float()) :: {:ok, map()} | {:error, String.t()}
  def assign_delivery_zone(lat, lng) do
    matching_zone =
      Enum.find(@delivery_zones, fn zone ->
        within_radius?(lat, lng, zone.lat, zone.lng, zone.radius_km)
      end)

    case matching_zone do
      nil ->
        Logger.warning("No delivery zone found for coordinates (#{lat}, #{lng})")
        {:error, "Location (#{lat}, #{lng}) is outside all configured delivery zones"}

      zone ->
        distance = haversine_distance(lat, lng, zone.lat, zone.lng)
        Logger.info("Assigned zone #{zone.id} to location (#{lat}, #{lng})")
        {:ok, Map.put(zone, :distance_to_center_km, distance)}
    end
  end

  @spec within_radius?(float(), float(), float(), float(), float()) :: boolean()
  def within_radius?(lat, lng, center_lat, center_lng, radius_km) do
    haversine_distance(lat, lng, center_lat, center_lng) <= radius_km
  end

  @spec route_stops(list({float(), float()})) :: list(map())
  def route_stops(stops) when is_list(stops) do
    stops
    |> Enum.with_index(1)
    |> Enum.map(fn {{lat, lng}, idx} ->
      case assign_delivery_zone(lat, lng) do
        {:ok, zone} ->
          %{stop_index: idx, lat: lat, lng: lng, zone_id: zone.id, routable: true}

        {:error, _} ->
          %{stop_index: idx, lat: lat, lng: lng, zone_id: nil, routable: false}
      end
    end)
  end
  # VALIDATION: SMELL END

  @spec total_route_distance(list({float(), float()})) :: float()
  def total_route_distance([]), do: 0.0

  def total_route_distance(stops) do
    stops
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.reduce(0.0, fn [{lat1, lng1}, {lat2, lng2}], acc ->
      acc + haversine_distance(lat1, lng1, lat2, lng2)
    end)
    |> Float.round(3)
  end

  defp to_rad(degrees), do: degrees * :math.pi() / 180.0
end
```
