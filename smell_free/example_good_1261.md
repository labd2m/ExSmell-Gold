```elixir
defmodule Geo.Coordinates do
  @moduledoc """
  An immutable value object for a geographic coordinate pair.
  Enforces WGS-84 latitude and longitude bounds at construction time.
  """

  @enforce_keys [:latitude, :longitude]
  defstruct [:latitude, :longitude]

  @type t :: %__MODULE__{latitude: float(), longitude: float()}

  @spec new(float(), float()) :: {:ok, t()} | {:error, :invalid_coordinates}
  def new(lat, lng) when is_float(lat) and is_float(lng) do
    if valid_latitude?(lat) and valid_longitude?(lng) do
      {:ok, %__MODULE__{latitude: lat, longitude: lng}}
    else
      {:error, :invalid_coordinates}
    end
  end

  def new(lat, lng) when is_integer(lat) and is_integer(lng) do
    new(lat * 1.0, lng * 1.0)
  end

  def new(lat, lng) when is_integer(lat) and is_float(lng), do: new(lat * 1.0, lng)
  def new(lat, lng) when is_float(lat) and is_integer(lng), do: new(lat, lng * 1.0)
  def new(_lat, _lng), do: {:error, :invalid_coordinates}

  @spec distance_km(t(), t()) :: float()
  def distance_km(%__MODULE__{} = from, %__MODULE__{} = to) do
    haversine(from, to)
  end

  @spec within_radius?(t(), t(), float()) :: boolean()
  def within_radius?(%__MODULE__{} = point, %__MODULE__{} = center, radius_km)
      when is_float(radius_km) and radius_km > 0.0 do
    distance_km(point, center) <= radius_km
  end

  @spec to_tuple(t()) :: {float(), float()}
  def to_tuple(%__MODULE__{latitude: lat, longitude: lng}), do: {lat, lng}

  defp valid_latitude?(lat), do: lat >= -90.0 and lat <= 90.0
  defp valid_longitude?(lng), do: lng >= -180.0 and lng <= 180.0

  defp haversine(%__MODULE__{latitude: lat1, longitude: lng1},
                 %__MODULE__{latitude: lat2, longitude: lng2}) do
    r = 6_371.0
    dlat = degrees_to_radians(lat2 - lat1)
    dlng = degrees_to_radians(lng2 - lng1)
    rlat1 = degrees_to_radians(lat1)
    rlat2 = degrees_to_radians(lat2)

    a = :math.sin(dlat / 2) ** 2 + :math.cos(rlat1) * :math.cos(rlat2) * :math.sin(dlng / 2) ** 2
    c = 2 * :math.atan2(:math.sqrt(a), :math.sqrt(1 - a))
    r * c
  end

  defp degrees_to_radians(deg), do: deg * :math.pi() / 180.0
end

defmodule Geo.BoundingBox do
  @moduledoc """
  An axis-aligned bounding box defined by its south-west and north-east corners.
  Used for spatial containment checks and viewport queries.
  """

  alias Geo.Coordinates

  @enforce_keys [:south_west, :north_east]
  defstruct [:south_west, :north_east]

  @type t :: %__MODULE__{south_west: Coordinates.t(), north_east: Coordinates.t()}

  @spec new(Coordinates.t(), Coordinates.t()) :: {:ok, t()} | {:error, :invalid_bounding_box}
  def new(%Coordinates{} = sw, %Coordinates{} = ne) do
    if sw.latitude < ne.latitude and sw.longitude < ne.longitude do
      {:ok, %__MODULE__{south_west: sw, north_east: ne}}
    else
      {:error, :invalid_bounding_box}
    end
  end

  @spec contains?(t(), Coordinates.t()) :: boolean()
  def contains?(%__MODULE__{south_west: sw, north_east: ne}, %Coordinates{} = point) do
    point.latitude >= sw.latitude and point.latitude <= ne.latitude and
      point.longitude >= sw.longitude and point.longitude <= ne.longitude
  end

  @spec center(t()) :: Coordinates.t()
  def center(%__MODULE__{south_west: sw, north_east: ne}) do
    mid_lat = (sw.latitude + ne.latitude) / 2.0
    mid_lng = (sw.longitude + ne.longitude) / 2.0
    {:ok, coords} = Coordinates.new(mid_lat, mid_lng)
    coords
  end

  @spec filter_within(t(), list(Coordinates.t())) :: list(Coordinates.t())
  def filter_within(%__MODULE__{} = box, points) when is_list(points) do
    Enum.filter(points, &contains?(box, &1))
  end
end
```
