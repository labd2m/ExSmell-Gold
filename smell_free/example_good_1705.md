```elixir
defmodule Geo.BoundingBox do
  @moduledoc """
  Represents and operates on geographic bounding boxes defined by corner coordinates.
  Provides containment checks, intersections, and area computation.
  """

  @type degrees :: float()
  @type coordinates :: %{lat: degrees(), lng: degrees()}

  @type t :: %__MODULE__{
    min_lat: degrees(),
    max_lat: degrees(),
    min_lng: degrees(),
    max_lng: degrees()
  }

  defstruct [:min_lat, :max_lat, :min_lng, :max_lng]

  @spec from_corners(coordinates(), coordinates()) :: {:ok, t()} | {:error, String.t()}
  def from_corners(%{lat: lat1, lng: lng1}, %{lat: lat2, lng: lng2})
      when is_float(lat1) and is_float(lat2) and is_float(lng1) and is_float(lng2) do
    with :ok <- validate_lat(lat1),
         :ok <- validate_lat(lat2),
         :ok <- validate_lng(lng1),
         :ok <- validate_lng(lng2) do
      box = %__MODULE__{
        min_lat: min(lat1, lat2),
        max_lat: max(lat1, lat2),
        min_lng: min(lng1, lng2),
        max_lng: max(lng1, lng2)
      }
      {:ok, box}
    end
  end

  def from_corners(_, _), do: {:error, "Coordinates must have float lat and lng fields"}

  @spec from_center(coordinates(), float()) :: {:ok, t()} | {:error, String.t()}
  def from_center(%{lat: lat, lng: lng}, radius_km)
      when is_float(lat) and is_float(lng) and is_float(radius_km) and radius_km > 0.0 do
    delta_lat = radius_km / 111.0
    delta_lng = radius_km / (111.0 * :math.cos(lat * :math.pi() / 180.0))

    from_corners(
      %{lat: lat - delta_lat, lng: lng - delta_lng},
      %{lat: lat + delta_lat, lng: lng + delta_lng}
    )
  end

  def from_center(_, _), do: {:error, "Invalid center or non-positive radius"}

  @spec contains?(t(), coordinates()) :: boolean()
  def contains?(%__MODULE__{} = box, %{lat: lat, lng: lng})
      when is_float(lat) and is_float(lng) do
    lat >= box.min_lat and lat <= box.max_lat and
      lng >= box.min_lng and lng <= box.max_lng
  end

  @spec intersects?(t(), t()) :: boolean()
  def intersects?(%__MODULE__{} = a, %__MODULE__{} = b) do
    a.min_lat <= b.max_lat and a.max_lat >= b.min_lat and
      a.min_lng <= b.max_lng and a.max_lng >= b.min_lng
  end

  @spec intersection(t(), t()) :: {:ok, t()} | {:error, :no_intersection}
  def intersection(%__MODULE__{} = a, %__MODULE__{} = b) do
    if intersects?(a, b) do
      box = %__MODULE__{
        min_lat: max(a.min_lat, b.min_lat),
        max_lat: min(a.max_lat, b.max_lat),
        min_lng: max(a.min_lng, b.min_lng),
        max_lng: min(a.max_lng, b.max_lng)
      }
      {:ok, box}
    else
      {:error, :no_intersection}
    end
  end

  @spec area_sq_km(t()) :: float()
  def area_sq_km(%__MODULE__{min_lat: min_lat, max_lat: max_lat, min_lng: min_lng, max_lng: max_lng}) do
    lat_km = (max_lat - min_lat) * 111.0
    mid_lat = (min_lat + max_lat) / 2.0
    lng_km = (max_lng - min_lng) * 111.0 * :math.cos(mid_lat * :math.pi() / 180.0)
    lat_km * lng_km
  end

  @spec to_bounds(t()) :: %{north: float(), south: float(), east: float(), west: float()}
  def to_bounds(%__MODULE__{min_lat: s, max_lat: n, min_lng: w, max_lng: e}) do
    %{north: n, south: s, east: e, west: w}
  end

  @spec validate_lat(degrees()) :: :ok | {:error, String.t()}
  defp validate_lat(lat) when lat >= -90.0 and lat <= 90.0, do: :ok
  defp validate_lat(lat), do: {:error, "Latitude #{lat} out of range [-90, 90]"}

  @spec validate_lng(degrees()) :: :ok | {:error, String.t()}
  defp validate_lng(lng) when lng >= -180.0 and lng <= 180.0, do: :ok
  defp validate_lng(lng), do: {:error, "Longitude #{lng} out of range [-180, 180]"}
end
```
