```elixir
defmodule MyApp.Logistics.GeoFenceChecker do
  @moduledoc """
  Determines whether a GPS coordinate falls within any of a named set of
  geo-fences. Fences are stored as Postgres `geography` polygons and
  looked up via a PostGIS `ST_Contains` query. Results are cached per
  coordinate (rounded to 4 decimal places) using a short TTL to avoid
  hammering the database from high-frequency telemetry streams.
  """

  alias MyApp.Repo
  alias MyApp.Logistics.GeoFence

  import Ecto.Query, warn: false

  @cache_ttl_ms 30_000
  @coordinate_precision 4

  @type lat :: float()
  @type lng :: float()
  @type fence_name :: String.t()

  @doc """
  Returns the names of all active geo-fences that contain `{lat, lng}`.
  An empty list means the coordinate is outside all registered fences.
  """
  @spec containing_fences(lat(), lng()) :: [fence_name()]
  def containing_fences(lat, lng) when is_float(lat) and is_float(lng) do
    cache_key = {round_coord(lat), round_coord(lng)}

    case MyApp.Cache.fetch(cache_key) do
      {:ok, names} ->
        names

      {:error, :not_found} ->
        names = query_fences(lat, lng)
        MyApp.Cache.put(cache_key, names, @cache_ttl_ms)
        names
    end
  end

  @doc """
  Returns `true` when `{lat, lng}` falls within the fence identified by
  `fence_name`.
  """
  @spec inside?(lat(), lng(), fence_name()) :: boolean()
  def inside?(lat, lng, fence_name) when is_float(lat) and is_float(lng) do
    fence_name in containing_fences(lat, lng)
  end

  @doc """
  Returns the distance in metres from `{lat, lng}` to the nearest point
  on the boundary of `fence_name`, or `nil` when the fence does not exist.
  """
  @spec distance_to_fence(lat(), lng(), fence_name()) :: float() | nil
  def distance_to_fence(lat, lng, fence_name) do
    sql = """
    SELECT ST_Distance(
      ST_GeographyFromText('POINT(' || $1 || ' ' || $2 || ')'),
      boundary
    )
    FROM geo_fences
    WHERE name = $3 AND active = true
    """

    case Repo.query(sql, [lng, lat, fence_name]) do
      {:ok, %{rows: [[distance]]}} -> distance
      _ -> nil
    end
  end

  @spec query_fences(lat(), lng()) :: [fence_name()]
  defp query_fences(lat, lng) do
    sql = """
    SELECT name FROM geo_fences
    WHERE active = true
      AND ST_Contains(
            boundary::geometry,
            ST_GeomFromText('POINT(' || $1 || ' ' || $2 || ')', 4326)
          )
    """

    case Repo.query(sql, [lng, lat]) do
      {:ok, %{rows: rows}} -> Enum.map(rows, &hd/1)
      {:error, _} -> []
    end
  end

  @spec round_coord(float()) :: float()
  defp round_coord(coord), do: Float.round(coord, @coordinate_precision)
end
```
