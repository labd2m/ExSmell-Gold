```elixir
defmodule Geo.BoundingBox do
  @moduledoc """
  Represents a geographic bounding box defined by its south-west and
  north-east corners. Provides containment checks and area calculations
  used by location search features. All arithmetic is pure and operates
  on struct fields via dot access.
  """

  @enforce_keys [:sw_lat, :sw_lng, :ne_lat, :ne_lng]
  defstruct [:sw_lat, :sw_lng, :ne_lat, :ne_lng]

  @type t :: %__MODULE__{
          sw_lat: float(),
          sw_lng: float(),
          ne_lat: float(),
          ne_lng: float()
        }

  @earth_radius_km 6_371.0

  @doc """
  Creates a bounding box from two coordinate pairs. Returns
  `{:error, :invalid_coordinates}` when any value is out of valid range.
  """
  @spec new(float(), float(), float(), float()) :: {:ok, t()} | {:error, :invalid_coordinates}
  def new(sw_lat, sw_lng, ne_lat, ne_lng)
      when is_float(sw_lat) and is_float(sw_lng) and
             is_float(ne_lat) and is_float(ne_lng) do
    if valid_lat?(sw_lat) and valid_lat?(ne_lat) and
         valid_lng?(sw_lng) and valid_lng?(ne_lng) and
         sw_lat <= ne_lat do
      {:ok, %__MODULE__{sw_lat: sw_lat, sw_lng: sw_lng, ne_lat: ne_lat, ne_lng: ne_lng}}
    else
      {:error, :invalid_coordinates}
    end
  end

  @doc "Returns true when the given point falls within the bounding box."
  @spec contains?(t(), float(), float()) :: boolean()
  def contains?(%__MODULE__{} = box, lat, lng)
      when is_float(lat) and is_float(lng) do
    lat >= box.sw_lat and lat <= box.ne_lat and
      lng_within?(box.sw_lng, box.ne_lng, lng)
  end

  @doc "Returns the centre point of the bounding box as `{lat, lng}`."
  @spec centre(t()) :: {float(), float()}
  def centre(%__MODULE__{sw_lat: sl, sw_lng: sw, ne_lat: nl, ne_lng: ne}) do
    {(sl + nl) / 2.0, normalise_lng((sw + ne) / 2.0)}
  end

  @doc """
  Estimates the diagonal distance of the bounding box in kilometres using
  the Haversine formula.
  """
  @spec diagonal_km(t()) :: float()
  def diagonal_km(%__MODULE__{sw_lat: sl, sw_lng: sw, ne_lat: nl, ne_lng: ne}) do
    haversine_km(sl, sw, nl, ne)
  end

  defp haversine_km(lat1, lng1, lat2, lng2) do
    dlat = to_radians(lat2 - lat1)
    dlng = to_radians(lng2 - lng1)
    rlat1 = to_radians(lat1)
    rlat2 = to_radians(lat2)

    a =
      :math.sin(dlat / 2) ** 2 +
        :math.cos(rlat1) * :math.cos(rlat2) * :math.sin(dlng / 2) ** 2

    c = 2 * :math.atan2(:math.sqrt(a), :math.sqrt(1 - a))
    @earth_radius_km * c
  end

  defp lng_within?(sw, ne, lng) when sw <= ne, do: lng >= sw and lng <= ne
  defp lng_within?(sw, ne, lng), do: lng >= sw or lng <= ne

  defp normalise_lng(lng) when lng > 180.0, do: lng - 360.0
  defp normalise_lng(lng) when lng < -180.0, do: lng + 360.0
  defp normalise_lng(lng), do: lng

  defp valid_lat?(lat), do: lat >= -90.0 and lat <= 90.0
  defp valid_lng?(lng), do: lng >= -180.0 and lng <= 180.0
  defp to_radians(deg), do: deg * :math.pi() / 180.0
end
```
