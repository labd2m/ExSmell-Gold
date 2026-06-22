# File: `example_good_821.md`

```elixir
defmodule Search.GeoSearch do
  @moduledoc """
  Provides geospatial proximity search over a list of geolocated entities
  using the Haversine formula for great-circle distance calculation.

  All computation is pure. Feed it a centre point, a radius, and a list
  of candidate locations to receive a sorted list of matches within range.
  """

  @earth_radius_km 6_371.0

  @type latitude :: float()
  @type longitude :: float()

  @type coordinate :: %{
          required(:lat) => latitude(),
          required(:lng) => longitude()
        }

  @type located_entity :: %{
          required(:id) => term(),
          required(:coordinates) => coordinate(),
          optional(atom()) => term()
        }

  @type proximity_result :: %{
          entity: located_entity(),
          distance_km: float(),
          distance_metres: non_neg_integer()
        }

  @doc """
  Returns all entities from `candidates` within `radius_km` of `centre`,
  sorted by distance ascending.
  """
  @spec within_radius([located_entity()], coordinate(), float()) :: [proximity_result()]
  def within_radius(candidates, centre, radius_km)
      when is_list(candidates) and is_map(centre) and
             is_number(radius_km) and radius_km > 0 do
    candidates
    |> Enum.map(fn entity ->
      km = haversine_km(centre, entity.coordinates)
      %{entity: entity, distance_km: km, distance_metres: round(km * 1_000)}
    end)
    |> Enum.filter(&(&1.distance_km <= radius_km))
    |> Enum.sort_by(& &1.distance_km)
  end

  @doc """
  Returns the `n` nearest entities to `centre` from `candidates`,
  regardless of distance.
  """
  @spec nearest(pos_integer(), [located_entity()], coordinate()) :: [proximity_result()]
  def nearest(n, candidates, centre)
      when is_integer(n) and n > 0 and is_list(candidates) do
    candidates
    |> Enum.map(fn entity ->
      km = haversine_km(centre, entity.coordinates)
      %{entity: entity, distance_km: km, distance_metres: round(km * 1_000)}
    end)
    |> Enum.sort_by(& &1.distance_km)
    |> Enum.take(n)
  end

  @doc """
  Computes the great-circle distance in kilometres between two coordinates
  using the Haversine formula.
  """
  @spec haversine_km(coordinate(), coordinate()) :: float()
  def haversine_km(%{lat: lat1, lng: lng1}, %{lat: lat2, lng: lng2}) do
    dlat = to_rad(lat2 - lat1)
    dlng = to_rad(lng2 - lng1)

    a =
      :math.sin(dlat / 2) * :math.sin(dlat / 2) +
        :math.cos(to_rad(lat1)) * :math.cos(to_rad(lat2)) *
          :math.sin(dlng / 2) * :math.sin(dlng / 2)

    c = 2 * :math.atan2(:math.sqrt(a), :math.sqrt(1 - a))
    Float.round(@earth_radius_km * c, 4)
  end

  @doc """
  Returns the geographic midpoint of a list of coordinates.

  Returns `nil` for an empty list.
  """
  @spec midpoint([coordinate()]) :: coordinate() | nil
  def midpoint([]), do: nil

  def midpoint(coordinates) when is_list(coordinates) do
    n = length(coordinates)
    avg_lat = coordinates |> Enum.sum_by(& &1.lat) |> Kernel./(n)
    avg_lng = coordinates |> Enum.sum_by(& &1.lng) |> Kernel./(n)
    %{lat: Float.round(avg_lat, 6), lng: Float.round(avg_lng, 6)}
  end

  @doc """
  Returns `true` when `coordinate` is within `radius_km` of `centre`.
  """
  @spec within?(coordinate(), coordinate(), float()) :: boolean()
  def within?(coordinate, centre, radius_km)
      when is_number(radius_km) and radius_km > 0 do
    haversine_km(centre, coordinate) <= radius_km
  end

  @doc """
  Clusters nearby entities using a simple grid-based approach.

  `cell_size_km` controls the resolution of the clustering grid.
  Returns a list of clusters, each with a centroid and member list.
  """
  @spec cluster([proximity_result()], float()) :: [map()]
  def cluster(results, cell_size_km) when is_list(results) and is_number(cell_size_km) do
    results
    |> Enum.group_by(fn %{entity: e} ->
      {round(e.coordinates.lat / cell_size_km * 111.32), round(e.coordinates.lng / cell_size_km * 111.32)}
    end)
    |> Enum.map(fn {_cell, members} ->
      coords = Enum.map(members, & &1.entity.coordinates)
      %{centroid: midpoint(coords), count: length(members), members: members}
    end)
    |> Enum.sort_by(& &1.count, :desc)
  end

  defp to_rad(degrees), do: degrees * :math.pi() / 180.0
end
```
