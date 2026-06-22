```elixir
defmodule Geo.BoundingBoxQuery do
  @moduledoc """
  Builds Ecto queries for geospatial bounding-box and radius-based lookups
  using PostGIS-compatible geography columns. Results can be ordered by
  proximity to a reference point with optional distance annotation.
  """

  import Ecto.Query

  @type coordinates :: %{lat: float(), lng: float()}
  @type bounding_box :: %{sw: coordinates(), ne: coordinates()}

  @earth_radius_m 6_371_000

  @spec within_box(Ecto.Query.t(), bounding_box(), atom(), atom()) :: Ecto.Query.t()
  def within_box(query, %{sw: sw, ne: ne}, lat_field, lng_field) do
    from(r in query,
      where:
        field(r, ^lat_field) >= ^sw.lat and
          field(r, ^lat_field) <= ^ne.lat and
          field(r, ^lng_field) >= ^sw.lng and
          field(r, ^lng_field) <= ^ne.lng
    )
  end

  @spec within_radius(Ecto.Query.t(), coordinates(), float(), atom(), atom()) :: Ecto.Query.t()
  def within_radius(query, %{lat: center_lat, lng: center_lng}, radius_km, lat_field, lng_field)
      when is_float(radius_km) and radius_km > 0 do
    lat_delta = radius_km / 111.0
    lng_delta = radius_km / (111.0 * :math.cos(center_lat * :math.pi() / 180))

    bounding_box = %{
      sw: %{lat: center_lat - lat_delta, lng: center_lng - lng_delta},
      ne: %{lat: center_lat + lat_delta, lng: center_lng + lng_delta}
    }

    query
    |> within_box(bounding_box, lat_field, lng_field)
    |> filter_haversine(center_lat, center_lng, radius_km, lat_field, lng_field)
  end

  @spec order_by_proximity(Ecto.Query.t(), coordinates(), atom(), atom()) :: Ecto.Query.t()
  def order_by_proximity(query, %{lat: ref_lat, lng: ref_lng}, lat_field, lng_field) do
    from(r in query,
      order_by:
        fragment(
          "((? - ?) * (? - ?)) + ((? - ?) * (? - ?))",
          field(r, ^lat_field),
          ^ref_lat,
          field(r, ^lat_field),
          ^ref_lat,
          field(r, ^lng_field),
          ^ref_lng,
          field(r, ^lng_field),
          ^ref_lng
        )
    )
  end

  @spec bounding_box_from_center(coordinates(), float()) :: bounding_box()
  def bounding_box_from_center(%{lat: lat, lng: lng}, radius_km) when radius_km > 0 do
    lat_delta = radius_km / 111.0
    lng_delta = radius_km / (111.0 * :math.cos(lat * :math.pi() / 180))

    %{
      sw: %{lat: lat - lat_delta, lng: lng - lng_delta},
      ne: %{lat: lat + lat_delta, lng: lng + lng_delta}
    }
  end

  @spec haversine_km(coordinates(), coordinates()) :: float()
  def haversine_km(%{lat: lat1, lng: lng1}, %{lat: lat2, lng: lng2}) do
    d_lat = (lat2 - lat1) * :math.pi() / 180
    d_lng = (lng2 - lng1) * :math.pi() / 180
    a = :math.sin(d_lat / 2) ** 2 +
        :math.cos(lat1 * :math.pi() / 180) *
        :math.cos(lat2 * :math.pi() / 180) *
        :math.sin(d_lng / 2) ** 2

    @earth_radius_m * 2 * :math.atan2(:math.sqrt(a), :math.sqrt(1 - a)) / 1000
  end

  @spec filter_haversine(Ecto.Query.t(), float(), float(), float(), atom(), atom()) ::
          Ecto.Query.t()
  defp filter_haversine(query, center_lat, center_lng, radius_km, lat_field, lng_field) do
    radius_m = radius_km * 1000
    lat_rad = center_lat * :math.pi() / 180

    from(r in query,
      where:
        fragment(
          "? * acos(LEAST(1.0, cos(?) * cos(? * pi() / 180) * cos((? * pi() / 180) - ?) + sin(?) * sin(? * pi() / 180)))",
          @earth_radius_m,
          ^(:math.cos(lat_rad)),
          field(r, ^lat_field),
          field(r, ^lng_field),
          ^(center_lng * :math.pi() / 180),
          ^(:math.sin(lat_rad)),
          field(r, ^lat_field)
        ) <= ^radius_m
    )
  end
end
```
