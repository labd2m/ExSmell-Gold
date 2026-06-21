# File: `example_good_99.md`

```elixir
defmodule Geo.BoundingBoxFilter do
  @moduledoc """
  Pure spatial filtering utilities for working with geographic bounding
  boxes and coordinate sets.

  All functions are stateless and side-effect free. Coordinates are
  represented as structured maps to make intent explicit and prevent
  latitude/longitude argument transposition bugs.
  """

  @type latitude :: float()
  @type longitude :: float()

  @type coordinate :: %{
          required(:lat) => latitude(),
          required(:lng) => longitude()
        }

  @type bounding_box :: %{
          required(:north) => latitude(),
          required(:south) => latitude(),
          required(:east) => longitude(),
          required(:west) => longitude()
        }

  @doc """
  Returns `true` when `coordinate` falls within `box`, inclusive of edges.
  """
  @spec contains?(bounding_box(), coordinate()) :: boolean()
  def contains?(
        %{north: north, south: south, east: east, west: west},
        %{lat: lat, lng: lng}
      )
      when is_float(lat) and is_float(lng) do
    lat >= south and lat <= north and within_longitude_range(lng, west, east)
  end

  @doc """
  Filters a list of coordinates, returning only those within `box`.
  """
  @spec filter([coordinate()], bounding_box()) :: [coordinate()]
  def filter(coordinates, box) when is_list(coordinates) and is_map(box) do
    Enum.filter(coordinates, &contains?(box, &1))
  end

  @doc """
  Builds the smallest bounding box that encloses all given coordinates.

  Returns `{:ok, bounding_box}` or `{:error, :empty_list}` when the list
  is empty.
  """
  @spec from_coordinates([coordinate()]) ::
          {:ok, bounding_box()} | {:error, :empty_list}
  def from_coordinates([]), do: {:error, :empty_list}

  def from_coordinates([first | rest]) do
    box =
      Enum.reduce(rest, initial_box(first), fn coord, acc ->
        expand_box(acc, coord)
      end)

    {:ok, box}
  end

  @doc """
  Expands a bounding box by a margin expressed in decimal degrees.

  Useful for adding a small buffer around a bounding box before querying.
  Latitude bounds are clamped to [-90, 90].
  """
  @spec expand(bounding_box(), float()) :: bounding_box()
  def expand(%{north: n, south: s, east: e, west: w}, margin_degrees)
      when is_float(margin_degrees) and margin_degrees >= 0.0 do
    %{
      north: min(n + margin_degrees, 90.0),
      south: max(s - margin_degrees, -90.0),
      east: e + margin_degrees,
      west: w - margin_degrees
    }
  end

  @doc """
  Returns `true` when two bounding boxes overlap.
  """
  @spec overlaps?(bounding_box(), bounding_box()) :: boolean()
  def overlaps?(a, b) do
    latitudes_overlap?(a, b) and longitudes_overlap?(a, b)
  end

  @doc """
  Computes the centre coordinate of a bounding box.
  """
  @spec centre(bounding_box()) :: coordinate()
  def centre(%{north: north, south: south, east: east, west: west}) do
    %{
      lat: (north + south) / 2.0,
      lng: (east + west) / 2.0
    }
  end

  @doc """
  Returns the approximate area of the bounding box in square decimal degrees.
  """
  @spec area(bounding_box()) :: float()
  def area(%{north: north, south: south, east: east, west: west}) do
    abs(north - south) * abs(east - west)
  end

  defp within_longitude_range(lng, west, east) when west <= east do
    lng >= west and lng <= east
  end

  defp within_longitude_range(lng, west, east) do
    lng >= west or lng <= east
  end

  defp initial_box(%{lat: lat, lng: lng}) do
    %{north: lat, south: lat, east: lng, west: lng}
  end

  defp expand_box(%{north: n, south: s, east: e, west: w}, %{lat: lat, lng: lng}) do
    %{
      north: max(n, lat),
      south: min(s, lat),
      east: max(e, lng),
      west: min(w, lng)
    }
  end

  defp latitudes_overlap?(a, b) do
    a.south <= b.north and a.north >= b.south
  end

  defp longitudes_overlap?(a, b) do
    a.west <= b.east and a.east >= b.west
  end
end
```
