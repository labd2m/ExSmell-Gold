```elixir
defmodule Geo.Coordinate do
  @moduledoc "Represents a geographic coordinate with validated latitude and longitude."

  @type t :: %__MODULE__{latitude: float(), longitude: float()}

  defstruct [:latitude, :longitude]

  @doc """
  Builds a `Coordinate` struct after validating range constraints.
  Latitude must be in [-90.0, 90.0] and longitude in [-180.0, 180.0].
  """
  @spec new(float(), float()) :: {:ok, t()} | {:error, :invalid_coordinates}
  def new(lat, lon)
      when is_float(lat) and is_float(lon) and
             lat >= -90.0 and lat <= 90.0 and
             lon >= -180.0 and lon <= 180.0 do
    {:ok, %__MODULE__{latitude: lat, longitude: lon}}
  end

  def new(_lat, _lon), do: {:error, :invalid_coordinates}
end

defmodule Geo.Distance do
  @moduledoc """
  Computes geodesic distances between coordinates using the Haversine formula.
  All returned distances are in meters.
  """

  alias Geo.Coordinate

  @earth_radius_meters 6_371_000.0

  @doc "Returns the great-circle distance in meters between two coordinates."
  @spec haversine(Coordinate.t(), Coordinate.t()) :: float()
  def haversine(%Coordinate{} = from, %Coordinate{} = to) do
    delta_lat = to_radians(to.latitude - from.latitude)
    delta_lon = to_radians(to.longitude - from.longitude)
    lat1 = to_radians(from.latitude)
    lat2 = to_radians(to.latitude)

    a = haversine_a(delta_lat, delta_lon, lat1, lat2)
    c = 2.0 * :math.atan2(:math.sqrt(a), :math.sqrt(1.0 - a))
    @earth_radius_meters * c
  end

  @doc "Returns the nearest coordinate from a list to the given origin."
  @spec nearest(Coordinate.t(), [Coordinate.t()]) :: {:ok, Coordinate.t()} | {:error, :empty}
  def nearest(_origin, []), do: {:error, :empty}
  def nearest(%Coordinate{} = origin, candidates) when is_list(candidates) do
    nearest =
      Enum.min_by(candidates, fn candidate -> haversine(origin, candidate) end)
    {:ok, nearest}
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp to_radians(degrees), do: degrees * :math.pi() / 180.0

  defp haversine_a(delta_lat, delta_lon, lat1, lat2) do
    sin_dlat = :math.sin(delta_lat / 2.0)
    sin_dlon = :math.sin(delta_lon / 2.0)
    sin_dlat * sin_dlat + sin_dlon * sin_dlon * :math.cos(lat1) * :math.cos(lat2)
  end
end

defmodule Geo.BoundingBox do
  @moduledoc """
  Represents an axis-aligned geographic bounding box defined by
  southwest and northeast corners.
  """

  alias Geo.Coordinate

  @type t :: %__MODULE__{southwest: Coordinate.t(), northeast: Coordinate.t()}

  defstruct [:southwest, :northeast]

  @doc "Constructs a bounding box from two corners after validating ordering."
  @spec new(Coordinate.t(), Coordinate.t()) :: {:ok, t()} | {:error, :invalid_bounds}
  def new(%Coordinate{} = sw, %Coordinate{} = ne) do
    if sw.latitude <= ne.latitude and sw.longitude <= ne.longitude do
      {:ok, %__MODULE__{southwest: sw, northeast: ne}}
    else
      {:error, :invalid_bounds}
    end
  end

  @doc "Returns true when the given coordinate falls within the bounding box."
  @spec contains?(t(), Coordinate.t()) :: boolean()
  def contains?(%__MODULE__{southwest: sw, northeast: ne}, %Coordinate{} = point) do
    point.latitude >= sw.latitude and point.latitude <= ne.latitude and
      point.longitude >= sw.longitude and point.longitude <= ne.longitude
  end

  @doc "Filters a list of coordinates to those inside the bounding box."
  @spec filter_inside(t(), [Coordinate.t()]) :: [Coordinate.t()]
  def filter_inside(%__MODULE__{} = box, coordinates) when is_list(coordinates) do
    Enum.filter(coordinates, &contains?(box, &1))
  end
end
```
