```elixir
defmodule Logistics.RouteOptimizer do
  @moduledoc """
  Scores and selects optimal delivery routes based on distance,
  stop count, and operational constraints supplied by the dispatcher.
  """

  require Logger

  @default_distance_weight 0.6
  @default_stop_weight     0.4

  @type route       :: %{id: String.t(), stops: list(map()), total_km: float()}
  @type constraints :: %{optional(atom()) => term()}

  @spec select_best(list(route()), constraints()) :: {:ok, route()} | {:error, :no_routes}
  def select_best([], _constraints), do: {:error, :no_routes}

  def select_best(routes, constraints) do
    best =
      routes
      |> Enum.map(fn route -> {route, score_route(route, constraints)} end)
      |> Enum.min_by(fn {_route, score} -> score end)
      |> elem(0)

    Logger.info("Selected route #{best.id} with #{length(best.stops)} stops")
    {:ok, best}
  end

  @spec score_route(route(), constraints()) :: float()
  def score_route(route, constraints) do
    max_distance  = constraints[:max_distance]
    max_stops     = constraints[:max_stops]
    priority_zone = constraints[:priority_zone]

    distance_penalty =
      if max_distance && route.total_km > max_distance do
        (route.total_km - max_distance) * 2.0
      else
        0.0
      end

    stop_penalty =
      if max_stops && length(route.stops) > max_stops do
        (length(route.stops) - max_stops) * 5.0
      else
        0.0
      end

    zone_bonus =
      if priority_zone do
        stops_in_zone =
          Enum.count(route.stops, fn stop -> stop.zone == priority_zone end)
        stops_in_zone * -3.0
      else
        0.0
      end

    base_score =
      route.total_km * @default_distance_weight +
        length(route.stops) * @default_stop_weight

    base_score + distance_penalty + stop_penalty + zone_bonus
  end

  @spec feasible?(route(), constraints()) :: boolean()
  def feasible?(route, constraints) do
    max_distance = Map.fetch!(constraints, :max_distance)
    max_stops    = Map.fetch!(constraints, :max_stops)

    route.total_km <= max_distance && length(route.stops) <= max_stops
  end

  @spec summarize(list(route())) :: map()
  def summarize(routes) do
    total_km    = routes |> Enum.map(& &1.total_km) |> Enum.sum()
    total_stops = routes |> Enum.map(fn r -> length(r.stops) end) |> Enum.sum()

    %{
      route_count: length(routes),
      total_km: Float.round(total_km, 2),
      total_stops: total_stops,
      avg_km_per_route: Float.round(total_km / max(length(routes), 1), 2)
    }
  end
end
```
