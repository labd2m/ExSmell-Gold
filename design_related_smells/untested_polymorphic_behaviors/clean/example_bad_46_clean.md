```elixir
defmodule Logistics.DispatchPlanner do
  @moduledoc """
  Plans and optimizes dispatch routes for last-mile delivery operations.
  Handles stop consolidation, vehicle assignment, and route sequencing.
  """

  alias Logistics.{Vehicle, Stop, Route, DriverAssignment}

  @max_stops_per_route 25
  @max_weight_kg 1000.0
  @dispatch_window_hours 2

  def create_dispatch_plan(warehouse_id, date, opts \\ []) do
    vehicle_filter = Keyword.get(opts, :vehicle_type, :any)
    priority_zones = Keyword.get(opts, :priority_zones, [])

    with {:ok, pending_stops} <- Stop.fetch_pending(warehouse_id, date),
         {:ok, vehicles} <- Vehicle.available_for(warehouse_id, date, vehicle_filter),
         {:ok, consolidated} <- consolidate_and_sort(pending_stops, priority_zones),
         {:ok, routes} <- assign_to_vehicles(consolidated, vehicles) do
      plan = %{
        warehouse_id: warehouse_id,
        date: date,
        routes: routes,
        total_stops: length(consolidated),
        vehicle_count: length(vehicles),
        created_at: DateTime.utc_now()
      }

      {:ok, plan}
    end
  end

  def consolidate_and_sort(stops, priority_zones) do
    priority = Enum.filter(stops, fn s -> s.zone in priority_zones end)
    regular = Enum.reject(stops, fn s -> s.zone in priority_zones end)

    sorted_priority = Enum.sort_by(priority, & &1.time_window_start, DateTime)
    sorted_regular = Enum.sort_by(regular, & &1.time_window_start, DateTime)

    {:ok, sorted_priority ++ sorted_regular}
  end

  def consolidate_pickup_stops(stop_lists) do
    stop_lists
    |> Enum.concat()
    |> Enum.uniq_by(& &1.stop_id)
    |> Enum.sort_by(& &1.scheduled_at, DateTime)
  end

  def assign_to_vehicles(stops, vehicles) do
    chunks = Enum.chunk_every(stops, @max_stops_per_route)

    if length(chunks) > length(vehicles) do
      {:error, {:insufficient_vehicles, length(chunks), length(vehicles)}}
    else
      routes =
        chunks
        |> Enum.zip(vehicles)
        |> Enum.map(fn {stop_chunk, vehicle} ->
          total_weight = Enum.sum(Enum.map(stop_chunk, & &1.package_weight_kg))

          if total_weight > @max_weight_kg do
            {:error, {:overweight_route, vehicle.id, total_weight}}
          else
            %Route{
              vehicle_id: vehicle.id,
              stops: stop_chunk,
              estimated_weight_kg: total_weight,
              status: :planned
            }
          end
        end)

      errors = Enum.filter(routes, &match?({:error, _}, &1))

      if errors == [] do
        {:ok, routes}
      else
        {:error, {:route_assignment_errors, errors}}
      end
    end
  end

  def estimate_route_duration(%Route{stops: stops, vehicle_id: vehicle_id}) do
    with {:ok, vehicle} <- Vehicle.fetch(vehicle_id) do
      avg_stop_minutes = 8
      travel_minutes = estimate_travel_time(stops, vehicle.average_speed_kmh)
      total_minutes = avg_stop_minutes * length(stops) + travel_minutes
      {:ok, total_minutes}
    end
  end

  defp estimate_travel_time(stops, avg_speed_kmh) do
    total_km =
      stops
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.reduce(0.0, fn [a, b], acc ->
        acc + haversine_km(a.coordinates, b.coordinates)
      end)

    round(total_km / avg_speed_kmh * 60)
  end

  defp haversine_km(_coord_a, _coord_b), do: 5.0
end
```
