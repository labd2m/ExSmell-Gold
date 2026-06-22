```elixir
defmodule Platform.GeoBoundary do
  @moduledoc """
  Pure-function utilities for geographic boundary checks.

  Supports point-in-polygon testing using the ray-casting algorithm,
  bounding-box intersection, and matching a coordinate against a
  set of named regions (e.g., delivery zones, coverage areas).
  """

  @type lat :: float()
  @type lng :: float()
  @type coord :: {lat(), lng()}
  @type polygon :: [coord()]
  @type region :: %{name: String.t(), polygon: polygon()}

  @doc """
  Returns `true` if `point` lies inside `polygon` using ray casting.
  Points on the boundary are considered inside.
  """
  @spec point_in_polygon?(coord(), polygon()) :: boolean()
  def point_in_polygon?({px, py}, polygon) when is_list(polygon) do
    n = length(polygon)
    vertices = polygon ++ [List.first(polygon)]

    {inside, _} =
      vertices
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.reduce({false, {px, py}}, fn [{ax, ay}, {bx, by}], {inside, point} ->
        {x, y} = point
        crosses = ay > y != by > y and x < (bx - ax) * (y - ay) / (by - ay) + ax
        {if(crosses, do: not inside, else: inside), point}
      end)

    inside
  end

  @doc """
  Returns the first `region` whose polygon contains `point`, or `nil`.
  """
  @spec find_region(coord(), [region()]) :: region() | nil
  def find_region(point, regions) when is_list(regions) do
    Enum.find(regions, fn %{polygon: polygon} ->
      point_in_polygon?(point, polygon)
    end)
  end

  @doc """
  Returns all regions containing `point`.
  """
  @spec regions_containing(coord(), [region()]) :: [region()]
  def regions_containing(point, regions) when is_list(regions) do
    Enum.filter(regions, fn %{polygon: polygon} ->
      point_in_polygon?(point, polygon)
    end)
  end

  @doc """
  Returns `true` if two axis-aligned bounding boxes overlap.
  Each box is `{sw_coord, ne_coord}`.
  """
  @spec bounding_boxes_overlap?({coord(), coord()}, {coord(), coord()}) :: boolean()
  def bounding_boxes_overlap?({sw1, ne1}, {sw2, ne2}) do
    {sw1_lat, sw1_lng} = sw1
    {ne1_lat, ne1_lng} = ne1
    {sw2_lat, sw2_lng} = sw2
    {ne2_lat, ne2_lng} = ne2

    sw1_lat <= ne2_lat and ne1_lat >= sw2_lat and
      sw1_lng <= ne2_lng and ne1_lng >= sw2_lng
  end

  @doc """
  Computes the bounding box of a polygon as `{sw_coord, ne_coord}`.
  """
  @spec bounding_box(polygon()) :: {coord(), coord()}
  def bounding_box(polygon) when is_list(polygon) and polygon != [] do
    lats = Enum.map(polygon, &elem(&1, 0))
    lngs = Enum.map(polygon, &elem(&1, 1))
    {{Enum.min(lats), Enum.min(lngs)}, {Enum.max(lats), Enum.max(lngs)}}
  end

  @doc """
  Returns the centroid of a polygon as `{lat, lng}`.
  """
  @spec centroid(polygon()) :: coord()
  def centroid(polygon) when is_list(polygon) and polygon != [] do
    n = length(polygon)
    {sum_lat, sum_lng} = Enum.reduce(polygon, {0.0, 0.0}, fn {lat, lng}, {sa, sl} ->
      {sa + lat, sl + lng}
    end)
    {sum_lat / n, sum_lng / n}
  end

  @doc """
  Returns `true` if `point` is within `radius_km` of the polygon centroid.
  A faster but less precise pre-filter before full point-in-polygon testing.
  """
  @spec within_centroid_radius?(coord(), polygon(), float()) :: boolean()
  def within_centroid_radius?(point, polygon, radius_km) do
    center = centroid(polygon)
    {lat1, lng1} = center
    {lat2, lng2} = point

    dlat = to_rad(lat2 - lat1)
    dlng = to_rad(lng2 - lng1)
    a = :math.sin(dlat / 2) ** 2 + :math.cos(to_rad(lat1)) * :math.cos(to_rad(lat2)) * :math.sin(dlng / 2) ** 2
    distance_km = 6371.0 * 2 * :math.atan2(:math.sqrt(a), :math.sqrt(1 - a))
    distance_km <= radius_km
  end

  defp to_rad(deg), do: deg * :math.pi() / 180
end
```
