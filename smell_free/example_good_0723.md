```elixir
defmodule Platform.GeoQuery do
  @moduledoc """
  Ecto query helpers for geographic proximity searches using PostgreSQL's
  `earthdistance` and `cube` extensions.

  Schemas must expose `latitude` and `longitude` float columns. All distances
  are in kilometres unless otherwise specified. Results can be ordered by
  proximity and filtered by a radius.
  """

  import Ecto.Query, only: [from: 2]
  alias Platform.Repo

  @earth_radius_km 6371.0

  @type lat :: float()
  @type lng :: float()
  @type km :: float()
  @type coord :: {lat(), lng()}
  @type geo_result(schema) :: %{record: schema, distance_km: float()}

  @doc """
  Returns records within `radius_km` of `{lat, lng}`, ordered by proximity.
  Each result includes the calculated distance in kilometres.
  """
  @spec within_radius(Ecto.Queryable.t(), coord(), km(), keyword()) :: [geo_result(struct())]
  def within_radius(queryable, {lat, lng}, radius_km, opts \\ [])
      when is_float(lat) and is_float(lng) and is_float(radius_km) do
    limit = Keyword.get(opts, :limit, 50)
    preloads = Keyword.get(opts, :preload, [])

    results =
      from(r in queryable,
        where:
          fragment(
            "earth_box(ll_to_earth(?, ?), ?) @> ll_to_earth(?, ?)",
            ^lat, ^lng, ^(radius_km * 1000),
            r.latitude, r.longitude
          ),
        select: %{
          record: r,
          distance_km:
            fragment(
              "earth_distance(ll_to_earth(?, ?), ll_to_earth(?, ?)) / 1000.0",
              ^lat, ^lng, r.latitude, r.longitude
            )
        },
        order_by: [
          asc:
            fragment(
              "earth_distance(ll_to_earth(?, ?), ll_to_earth(?, ?))",
              ^lat, ^lng, r.latitude, r.longitude
            )
        ],
        limit: ^limit
      )
      |> Repo.all()

    if preloads == [] do
      results
    else
      records = Enum.map(results, & &1.record)
      loaded = Repo.preload(records, preloads)
      Enum.zip_with(results, loaded, fn r, record -> %{r | record: record} end)
    end
  end

  @doc """
  Returns the nearest `count` records to `{lat, lng}` with no radius limit.
  """
  @spec nearest(Ecto.Queryable.t(), coord(), pos_integer()) :: [geo_result(struct())]
  def nearest(queryable, {lat, lng}, count \\ 10)
      when is_float(lat) and is_float(lng) and is_integer(count) do
    from(r in queryable,
      where: not is_nil(r.latitude) and not is_nil(r.longitude),
      select: %{
        record: r,
        distance_km:
          fragment(
            "earth_distance(ll_to_earth(?, ?), ll_to_earth(?, ?)) / 1000.0",
            ^lat, ^lng, r.latitude, r.longitude
          )
      },
      order_by: [
        asc:
          fragment(
            "earth_distance(ll_to_earth(?, ?), ll_to_earth(?, ?))",
            ^lat, ^lng, r.latitude, r.longitude
          )
      ],
      limit: ^count
    )
    |> Repo.all()
  end

  @doc """
  Computes the great-circle distance between two coordinates in kilometres.
  Uses the Haversine formula for accuracy.
  """
  @spec haversine_km(coord(), coord()) :: km()
  def haversine_km({lat1, lng1}, {lat2, lng2}) do
    dlat = to_rad(lat2 - lat1)
    dlng = to_rad(lng2 - lng1)
    rlat1 = to_rad(lat1)
    rlat2 = to_rad(lat2)

    a =
      :math.sin(dlat / 2) ** 2 +
        :math.cos(rlat1) * :math.cos(rlat2) * :math.sin(dlng / 2) ** 2

    c = 2 * :math.atan2(:math.sqrt(a), :math.sqrt(1 - a))
    @earth_radius_km * c
  end

  @doc "Returns the bounding box `{sw, ne}` for a circle of `radius_km` around `center`."
  @spec bounding_box(coord(), km()) :: {coord(), coord()}
  def bounding_box({lat, lng}, radius_km) do
    delta_lat = radius_km / @earth_radius_km * (180 / :math.pi())
    delta_lng = delta_lat / :math.cos(to_rad(lat))
    {{lat - delta_lat, lng - delta_lng}, {lat + delta_lat, lng + delta_lng}}
  end

  defp to_rad(degrees), do: degrees * :math.pi() / 180
end
```
