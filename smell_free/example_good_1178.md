**File:** `example_good_1178.md`

```elixir
defmodule Geo.Coordinate do
  @moduledoc "Represents a geographic coordinate with validated latitude and longitude."

  @enforce_keys [:lat, :lng]
  defstruct [:lat, :lng]

  @type t :: %__MODULE__{
          lat: float(),
          lng: float()
        }

  @spec new(number(), number()) :: {:ok, t()} | {:error, String.t()}
  def new(lat, lng) when is_number(lat) and is_number(lng) do
    cond do
      lat < -90.0 or lat > 90.0 ->
        {:error, "latitude must be between -90 and 90, got #{lat}"}

      lng < -180.0 or lng > 180.0 ->
        {:error, "longitude must be between -180 and 180, got #{lng}"}

      true ->
        {:ok, %__MODULE__{lat: lat / 1, lng: lng / 1}}
    end
  end
end

defmodule Geo.BoundingBox do
  @moduledoc """
  Represents a rectangular geographic bounding box defined by
  southwest and northeast corner coordinates.
  """

  alias Geo.Coordinate

  @enforce_keys [:sw, :ne]
  defstruct [:sw, :ne]

  @type t :: %__MODULE__{
          sw: Coordinate.t(),
          ne: Coordinate.t()
        }

  @spec new(Coordinate.t(), Coordinate.t()) :: {:ok, t()} | {:error, String.t()}
  def new(%Coordinate{} = sw, %Coordinate{} = ne) do
    cond do
      sw.lat >= ne.lat ->
        {:error, "southwest latitude must be less than northeast latitude"}

      sw.lng >= ne.lng ->
        {:error, "southwest longitude must be less than northeast longitude"}

      true ->
        {:ok, %__MODULE__{sw: sw, ne: ne}}
    end
  end

  @spec contains?(t(), Coordinate.t()) :: boolean()
  def contains?(%__MODULE__{sw: sw, ne: ne}, %Coordinate{lat: lat, lng: lng}) do
    lat >= sw.lat and lat <= ne.lat and lng >= sw.lng and lng <= ne.lng
  end

  @spec from_center(Coordinate.t(), float()) :: {:ok, t()} | {:error, String.t()}
  def from_center(%Coordinate{lat: lat, lng: lng}, radius_km) when radius_km > 0 do
    lat_delta = radius_km / 111.0
    lng_delta = radius_km / (111.0 * :math.cos(lat * :math.pi() / 180.0))

    with {:ok, sw} <- Coordinate.new(lat - lat_delta, lng - lng_delta),
         {:ok, ne} <- Coordinate.new(lat + lat_delta, lng + lng_delta) do
      new(sw, ne)
    end
  end

  def from_center(_coord, radius_km), do: {:error, "radius_km must be positive, got #{radius_km}"}
end

defmodule Geo.Distance do
  @moduledoc "Calculates distances between geographic coordinates using the Haversine formula."

  alias Geo.Coordinate

  @earth_radius_km 6371.0

  @spec haversine_km(Coordinate.t(), Coordinate.t()) :: float()
  def haversine_km(%Coordinate{} = from, %Coordinate{} = to) do
    dlat = deg_to_rad(to.lat - from.lat)
    dlng = deg_to_rad(to.lng - from.lng)

    a =
      :math.sin(dlat / 2) ** 2 +
        :math.cos(deg_to_rad(from.lat)) *
          :math.cos(deg_to_rad(to.lat)) *
          :math.sin(dlng / 2) ** 2

    c = 2 * :math.atan2(:math.sqrt(a), :math.sqrt(1 - a))
    @earth_radius_km * c
  end

  defp deg_to_rad(deg), do: deg * :math.pi() / 180.0
end

defmodule Geo.NearestNeighbor do
  @moduledoc """
  Finds the nearest points to a query coordinate from a list of candidates.
  Uses bounding box pre-filtering for efficiency before precise Haversine ranking.
  """

  alias Geo.{BoundingBox, Coordinate, Distance}

  @type point :: %{coordinate: Coordinate.t(), id: term()}

  @spec nearest(Coordinate.t(), [point()], keyword()) ::
          {:ok, [point()]} | {:error, String.t()}
  def nearest(%Coordinate{} = query, candidates, opts \\ []) do
    limit = Keyword.get(opts, :limit, 10)
    radius_km = Keyword.get(opts, :radius_km, 50.0)

    with {:ok, bbox} <- BoundingBox.from_center(query, radius_km) do
      results =
        candidates
        |> Enum.filter(fn %{coordinate: coord} -> BoundingBox.contains?(bbox, coord) end)
        |> Enum.map(fn point ->
          Map.put(point, :distance_km, Distance.haversine_km(query, point.coordinate))
        end)
        |> Enum.sort_by(& &1.distance_km)
        |> Enum.take(limit)

      {:ok, results}
    end
  end
end
```
