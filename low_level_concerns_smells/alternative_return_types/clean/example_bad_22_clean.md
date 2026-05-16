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
