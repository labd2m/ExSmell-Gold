# Code Smell: Alternative Return Types

## Metadata

- **Smell name:** Alternative Return Types
- **Expected smell location:** `Fleet.VehicleTracker.position/2`
- **Affected function(s):** `position/2`
- **Short explanation:** The `:as` option changes the return from a `{lat, lng}` coordinate tuple, to a full `%GeoPoint{}` struct with metadata, to a human-readable address string. These types share no structure and force every caller to handle them as completely separate cases.

---

```elixir
defmodule MyApp.Fleet.VehicleTracker do
  @moduledoc """
  Real-time vehicle position tracking for a logistics fleet.
  Integrates with GPS telemetry ingestion, geocoding services,
  and route deviation alerting.
  """

  alias MyApp.Fleet.TelemetryStore
  alias MyApp.Fleet.GeoPoint
  alias MyApp.Fleet.Geocoder
  alias MyApp.Fleet.RouteEngine

  @stale_threshold_seconds 300
  @position_precision 6

  defstruct [
    :vehicle_id, :latitude, :longitude,
    :altitude_m, :speed_kmh, :heading_deg,
    :accuracy_m, :recorded_at, :source
  ]

  def register_vehicle(vehicle_id, attrs) do
    %{
      vehicle_id: vehicle_id,
      plate: attrs[:plate],
      model: attrs[:model],
      fleet_group: attrs[:fleet_group],
      registered_at: DateTime.utc_now()
    }
  end

  # VALIDATION: SMELL START - Alternative Return Types
  # VALIDATION: This is a smell because opts[:as] produces three incompatible
  # return types: :coords returns a plain {lat, lng} float tuple, :point
  # returns a %GeoPoint{} struct with full telemetry metadata, and :address
  # returns a binary string from the geocoder. Callers consuming this result
  # must branch on which :as value they passed, or risk pattern-match failures
  # and incorrect data interpretation.
  def position(vehicle_id, opts \\ []) when is_list(opts) do
    as = Keyword.get(opts, :as, :coords)
    max_age = Keyword.get(opts, :max_age_seconds, @stale_threshold_seconds)
    include_stale = Keyword.get(opts, :include_stale, false)

    case TelemetryStore.latest(vehicle_id) do
      nil ->
        {:error, :no_position_data}

      reading ->
        age = DateTime.diff(DateTime.utc_now(), reading.recorded_at)

        if not include_stale and age > max_age do
          {:error, :stale_position}
        else
          lat = Float.round(reading.latitude, @position_precision)
          lng = Float.round(reading.longitude, @position_precision)

          case as do
            :coords ->
              {lat, lng}

            :point ->
              %GeoPoint{
                vehicle_id: vehicle_id,
                latitude: lat,
                longitude: lng,
                altitude_m: reading.altitude_m,
                speed_kmh: reading.speed_kmh,
                heading_deg: reading.heading_deg,
                accuracy_m: reading.accuracy_m,
                recorded_at: reading.recorded_at,
                source: reading.source,
                stale: age > max_age
              }

            :address ->
              case Geocoder.reverse(lat, lng) do
                {:ok, address} -> address
                {:error, _} -> "#{lat}, #{lng}"
              end
          end
        end
    end
  end
  # VALIDATION: SMELL END

  def history(vehicle_id, from, to) do
    TelemetryStore.range(vehicle_id, from, to)
  end

  def on_route?(vehicle_id, route_id) do
    case position(vehicle_id, as: :coords) do
      {lat, lng} -> RouteEngine.within_corridor?(route_id, lat, lng)
      {:error, _} -> false
    end
  end

  def distance_traveled(vehicle_id, from, to) do
    history(vehicle_id, from, to)
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.reduce(0.0, fn [a, b], acc ->
      acc + haversine(a.latitude, a.longitude, b.latitude, b.longitude)
    end)
  end

  defp haversine(lat1, lng1, lat2, lng2) do
    r = 6_371_000
    phi1 = lat1 * :math.pi() / 180
    phi2 = lat2 * :math.pi() / 180
    dphi = (lat2 - lat1) * :math.pi() / 180
    dlambda = (lng2 - lng1) * :math.pi() / 180
    a = :math.sin(dphi / 2) ** 2 + :math.cos(phi1) * :math.cos(phi2) * :math.sin(dlambda / 2) ** 2
    r * 2 * :math.atan2(:math.sqrt(a), :math.sqrt(1 - a))
  end
end
```
