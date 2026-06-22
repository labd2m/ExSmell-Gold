```elixir
defmodule Logistics.Routing.DistanceMatrix do
  @moduledoc """
  Builds and queries distance matrices for multi-stop logistics routing.

  Computes pairwise distances between depot and delivery locations,
  supporting nearest-neighbour and optimal route estimation queries.
  """

  alias Logistics.Routing.{Location, RouteSegment}

  @type coordinates :: %{latitude: float(), longitude: float()}
  @type distance_km :: float()
  @type matrix :: %{{String.t(), String.t()} => distance_km()}

  @earth_radius_km 6_371.0

  @doc """
  Builds a symmetric distance matrix for all provided locations.

  Returns a map keyed by `{from_id, to_id}` tuples with distances in kilometres.
  """
  @spec build([Location.t()]) :: matrix()
  def build(locations) when is_list(locations) do
    pairs = for a <- locations, b <- locations, a.id != b.id, do: {a, b}

    Map.new(pairs, fn {a, b} ->
      {{a.id, b.id}, haversine(a.coordinates, b.coordinates)}
    end)
  end

  @doc """
  Returns the nearest unvisited location from the current position.

  Returns `{:ok, location}` or `{:error, :no_unvisited_locations}`.
  """
  @spec nearest_unvisited(matrix(), String.t(), [Location.t()], MapSet.t()) ::
          {:ok, Location.t(), distance_km()} | {:error, :no_unvisited_locations}
  def nearest_unvisited(matrix, current_id, all_locations, visited_ids) do
    candidates =
      all_locations
      |> Enum.reject(fn loc -> MapSet.member?(visited_ids, loc.id) end)
      |> Enum.map(fn loc -> {loc, Map.get(matrix, {current_id, loc.id}, :infinity)} end)
      |> Enum.reject(fn {_, dist} -> dist == :infinity end)
      |> Enum.sort_by(fn {_, dist} -> dist end)

    case candidates do
      [] -> {:error, :no_unvisited_locations}
      [{location, distance} | _] -> {:ok, location, distance}
    end
  end

  @doc """
  Computes the total route distance for an ordered list of location IDs.
  """
  @spec total_route_distance(matrix(), [String.t()]) ::
          {:ok, distance_km()} | {:error, :missing_segment}
  def total_route_distance(_matrix, ids) when length(ids) < 2, do: {:ok, 0.0}

  def total_route_distance(matrix, ids) do
    ids
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.reduce_while({:ok, 0.0}, fn [from, to], {:ok, acc} ->
      case Map.fetch(matrix, {from, to}) do
        {:ok, dist} -> {:cont, {:ok, acc + dist}}
        :error -> {:halt, {:error, :missing_segment}}
      end
    end)
  end

  @doc """
  Builds an ordered list of route segments with distances from a location sequence.
  """
  @spec to_segments(matrix(), [Location.t()]) :: {:ok, [RouteSegment.t()]} | {:error, :missing_segment}
  def to_segments(_matrix, locations) when length(locations) < 2, do: {:ok, []}

  def to_segments(matrix, locations) do
    locations
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.reduce_while({:ok, []}, fn [from_loc, to_loc], {:ok, acc} ->
      case Map.fetch(matrix, {from_loc.id, to_loc.id}) do
        {:ok, dist} ->
          segment = %RouteSegment{from: from_loc, to: to_loc, distance_km: dist}
          {:cont, {:ok, [segment | acc]}}

        :error ->
          {:halt, {:error, :missing_segment}}
      end
    end)
    |> case do
      {:ok, segments} -> {:ok, Enum.reverse(segments)}
      error -> error
    end
  end

  defp haversine(%{latitude: lat1, longitude: lon1}, %{latitude: lat2, longitude: lon2}) do
    dlat = to_radians(lat2 - lat1)
    dlon = to_radians(lon2 - lon1)
    rlat1 = to_radians(lat1)
    rlat2 = to_radians(lat2)

    a =
      :math.sin(dlat / 2) ** 2 +
        :math.cos(rlat1) * :math.cos(rlat2) * :math.sin(dlon / 2) ** 2

    c = 2 * :math.atan2(:math.sqrt(a), :math.sqrt(1 - a))
    Float.round(@earth_radius_km * c, 3)
  end

  defp to_radians(degrees), do: degrees * :math.pi() / 180
end
```
