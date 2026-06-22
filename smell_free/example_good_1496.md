```elixir
defmodule Logistics.RouteOptimizer do
  @moduledoc """
  Computes optimized delivery routes for a fleet of vehicles given a set of stops.
  Uses a nearest-neighbor heuristic for route ordering with configurable constraints.
  """

  @type coordinates :: %{lat: float(), lng: float()}
  @type stop :: %{id: String.t(), location: coordinates(), priority: :standard | :urgent}
  @type route :: [stop()]
  @type vehicle :: %{id: String.t(), max_stops: pos_integer()}

  @spec plan(vehicle(), [stop()], coordinates()) :: {:ok, route()} | {:error, String.t()}
  def plan(%{max_stops: max_stops} = _vehicle, stops, depot)
      when is_list(stops) and is_map(depot) do
    if length(stops) > max_stops do
      {:error, "Stop count #{length(stops)} exceeds vehicle capacity #{max_stops}"}
    else
      ordered = sort_by_priority_then_distance(stops, depot)
      {:ok, ordered}
    end
  end

  @spec total_distance_km(route(), coordinates()) :: float()
  def total_distance_km([], _depot), do: 0.0

  def total_distance_km(route, depot) do
    {total, _} =
      Enum.reduce(route, {0.0, depot}, fn stop, {dist, current} ->
        leg = haversine_km(current, stop.location)
        {dist + leg, stop.location}
      end)

    last_stop = List.last(route)
    total + haversine_km(last_stop.location, depot)
  end

  @spec estimated_duration_minutes(route(), coordinates(), float()) :: float()
  def estimated_duration_minutes(route, depot, avg_speed_kmh)
      when is_float(avg_speed_kmh) and avg_speed_kmh > 0.0 do
    distance = total_distance_km(route, depot)
    hours = distance / avg_speed_kmh
    hours * 60.0
  end

  @spec sort_by_priority_then_distance([stop()], coordinates()) :: route()
  defp sort_by_priority_then_distance(stops, depot) do
    urgent = stops |> Enum.filter(&(&1.priority == :urgent)) |> nearest_neighbor_order(depot)
    standard = stops |> Enum.filter(&(&1.priority == :standard)) |> nearest_neighbor_order(depot)
    urgent ++ standard
  end

  @spec nearest_neighbor_order([stop()], coordinates()) :: route()
  defp nearest_neighbor_order([], _), do: []

  defp nearest_neighbor_order(stops, origin) do
    Enum.reduce(1..length(stops), {[], stops, origin}, fn _, {ordered, remaining, current} ->
      nearest = Enum.min_by(remaining, &haversine_km(current, &1.location))
      rest = Enum.reject(remaining, &(&1.id == nearest.id))
      {[nearest | ordered], rest, nearest.location}
    end)
    |> elem(0)
    |> Enum.reverse()
  end

  @spec haversine_km(coordinates(), coordinates()) :: float()
  defp haversine_km(%{lat: lat1, lng: lng1}, %{lat: lat2, lng: lng2}) do
    r = 6371.0
    d_lat = to_rad(lat2 - lat1)
    d_lng = to_rad(lng2 - lng1)

    a =
      :math.sin(d_lat / 2) * :math.sin(d_lat / 2) +
        :math.cos(to_rad(lat1)) * :math.cos(to_rad(lat2)) *
          :math.sin(d_lng / 2) * :math.sin(d_lng / 2)

    c = 2 * :math.atan2(:math.sqrt(a), :math.sqrt(1 - a))
    r * c
  end

  @spec to_rad(float()) :: float()
  defp to_rad(degrees), do: degrees * :math.pi() / 180.0
end
```
