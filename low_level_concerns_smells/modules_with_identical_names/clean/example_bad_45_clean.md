```elixir
# ── file: lib/geo/locator.ex ─────────────────────────────────────────────────

defmodule Geo.Locator do
  @moduledoc """
  IP geolocation, reverse geocoding, and spatial utilities.
  Defined in `lib/geo/locator.ex`.
  """

  alias Geo.{IPDatabase, GeocoderClient, RegionRegistry, TimezoneDB}

  @earth_radius_km 6_371.0
  @cache_ttl_seconds 3_600

  @type coordinates :: {float(), float()}
  @type ip_address :: String.t()

  @type geo_result :: %{
    ip: ip_address(),
    country_code: String.t(),
    country_name: String.t(),
    region: String.t(),
    city: String.t(),
    latitude: float(),
    longitude: float(),
    isp: String.t() | nil,
    is_vpn: boolean()
  }

  @doc """
  Resolve geolocation metadata for an IPv4 or IPv6 address.
  Returns `{:ok, geo_result}` or `{:error, reason}`.
  """
  @spec locate_ip(ip_address()) :: {:ok, geo_result()} | {:error, String.t()}
  def locate_ip(ip) when is_binary(ip) do
    cache_key = "geo:ip:#{ip}"

    case Geo.Cache.get(cache_key) do
      {:ok, cached} ->
        {:ok, cached}

      :miss ->
        case IPDatabase.lookup(ip) do
          {:ok, result} ->
            Geo.Cache.put(cache_key, result, ttl: @cache_ttl_seconds)
            {:ok, result}

          {:error, :not_found} ->
            {:error, "No geolocation data for IP: #{ip}"}

          {:error, reason} ->
            {:error, "IP lookup failed: #{inspect(reason)}"}
        end
    end
  end

  @doc "Convert latitude/longitude coordinates to a human-readable address."
  @spec reverse_geocode(float(), float()) :: {:ok, map()} | {:error, String.t()}
  def reverse_geocode(lat, lon)
      when is_float(lat) and is_float(lon)
      and lat >= -90 and lat <= 90
      and lon >= -180 and lon <= 180 do
    case GeocoderClient.reverse(lat, lon) do
      {:ok, address} ->
        {:ok, address}

      {:error, :quota_exceeded} ->
        {:error, "Geocoding quota exceeded — try again later"}

      {:error, reason} ->
        {:error, "Reverse geocode failed: #{inspect(reason)}"}
    end
  end

  def reverse_geocode(lat, lon) do
    {:error, "Invalid coordinates: lat=#{lat}, lon=#{lon}"}
  end

  @doc "Calculate the great-circle distance in km between two coordinate pairs."
  @spec distance_km(coordinates(), coordinates()) :: float()
  def distance_km({lat1, lon1}, {lat2, lon2}) do
    dlat = to_rad(lat2 - lat1)
    dlon = to_rad(lon2 - lon1)

    a =
      :math.sin(dlat / 2) ** 2 +
        :math.cos(to_rad(lat1)) * :math.cos(to_rad(lat2)) *
          :math.sin(dlon / 2) ** 2

    c = 2 * :math.atan2(:math.sqrt(a), :math.sqrt(1 - a))
    Float.round(@earth_radius_km * c, 2)
  end

  @doc "Check whether a coordinate pair falls within a named region."
  @spec within_region?(coordinates(), String.t()) :: boolean()
  def within_region?({lat, lon}, region_name) do
    case RegionRegistry.fetch(region_name) do
      {:ok, polygon} -> point_in_polygon?({lat, lon}, polygon)
      :not_found -> false
    end
  end

  @doc "Return the IANA timezone identifier for a coordinate pair."
  @spec timezone_for(float(), float()) :: {:ok, String.t()} | {:error, String.t()}
  def timezone_for(lat, lon) do
    case TimezoneDB.lookup(lat, lon) do
      {:ok, tz} -> {:ok, tz}
      {:error, reason} -> {:error, "Timezone lookup failed: #{inspect(reason)}"}
    end
  end

  defp to_rad(degrees), do: degrees * :math.pi() / 180.0

  defp point_in_polygon?({px, py}, polygon) do
    polygon
    |> Enum.chunk_every(2, 1, [List.first(polygon)])
    |> Enum.reduce(false, fn [{x1, y1}, {x2, y2}], acc ->
      if (y1 > py) != (y2 > py) and px < (x2 - x1) * (py - y1) / (y2 - y1) + x1 do
        not acc
      else
        acc
      end
    end)
  end
end


# ── file: lib/geo/locator_region_builder.ex 

defmodule Geo.Locator do
  @moduledoc """
  Region polygon management: create and update geographic boundary definitions.
  Was intended to be `Geo.Locator.RegionBuilder` but was accidentally given
  the same module name as the core locator module.
  """

  alias Geo.{RegionRegistry, GeocoderClient}

  @doc "Register a named region with a polygon of coordinate pairs."
  @spec register_region(String.t(), [{float(), float()}]) ::
          :ok | {:error, String.t()}
  def register_region(name, polygon) when is_list(polygon) and length(polygon) >= 3 do
    RegionRegistry.put(name, polygon)
  end

  def register_region(_name, polygon) do
    {:error, "A region polygon must have at least 3 vertices, got #{length(polygon)}"}
  end

  @doc "Build a circular region approximated as a polygon."
  @spec circle_region(String.t(), float(), float(), float(), pos_integer()) ::
          :ok | {:error, String.t()}
  def circle_region(name, center_lat, center_lon, radius_km, points \\ 32) do
    step = 2 * :math.pi() / points

    polygon =
      Enum.map(0..(points - 1), fn i ->
        angle = i * step
        dlat = radius_km / 111.0 * :math.cos(angle)
        dlon = radius_km / (111.0 * :math.cos(center_lat * :math.pi() / 180)) * :math.sin(angle)
        {center_lat + dlat, center_lon + dlon}
      end)

    register_region(name, polygon)
  end

  @doc "Build a region from a place name by geocoding its boundary."
  @spec region_from_place(String.t()) :: :ok | {:error, String.t()}
  def region_from_place(place_name) do
    with {:ok, %{bounds: bounds}} <- GeocoderClient.geocode(place_name) do
      polygon = bounds_to_polygon(bounds)
      register_region(place_name, polygon)
    end
  end

  defp bounds_to_polygon(%{northeast: ne, southwest: sw}) do
    [
      {ne.lat, sw.lng},
      {ne.lat, ne.lng},
      {sw.lat, ne.lng},
      {sw.lat, sw.lng}
    ]
  end
end

```
