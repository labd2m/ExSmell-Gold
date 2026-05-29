# Annotated Example — Code Smell: Long Function

## Metadata

- **Smell name:** Long Function
- **Expected smell location:** `Logistics.RouteOptimizer.plan_daily_routes/2`
- **Affected function(s):** `plan_daily_routes/2`
- **Short explanation:** `plan_daily_routes/2` performs delivery-window filtering, vehicle-capacity binpacking, distance-matrix construction, nearest-neighbour route ordering, time-estimate computation, driver-assignment, manifest generation, and dispatcher notification in one deeply nested function body.

---

```elixir
defmodule Logistics.RouteOptimizer do
  @moduledoc """
  Plans and optimises daily delivery routes across a fleet
  of vehicles using capacity constraints and time windows.
  """

  require Logger

  alias Logistics.{Delivery, Vehicle, Driver, DistanceMatrix, Manifest, DispatchNotifier}

  @max_route_hours   9.0
  @loading_time_min  5
  @speed_kmh         40.0

  # VALIDATION: SMELL START - Long Function
  # VALIDATION: This is a smell because `plan_daily_routes/2` inlines
  # delivery filtering, capacity binpacking, distance-matrix building,
  # nearest-neighbour sorting, ETA calculation, driver-assignment, manifest
  # persistence, and notification dispatch into a single function exceeding
  # 100 lines without extracting any of the seven discrete steps into
  # focused private helpers.
  def plan_daily_routes(depot, delivery_date, opts \\ []) do
    dry_run = Keyword.get(opts, :dry_run, false)

    Logger.info("Planning routes for #{depot.name} on #{delivery_date}")

    # 1. Load pending deliveries within their time windows
    all_deliveries =
      Delivery.list_pending_for_depot(depot.id, delivery_date)

    deliveries =
      Enum.filter(all_deliveries, fn d ->
        (is_nil(d.earliest_time) or Time.compare(d.earliest_time, ~T[18:00:00]) != :gt) and
          d.status == :pending
      end)

    if deliveries == [] do
      Logger.info("No deliveries to route for #{depot.name} on #{delivery_date}")
      {:ok, []}
    else
      # 2. Load available vehicles
      vehicles = Vehicle.available_for_depot(depot.id, delivery_date)

      if vehicles == [] do
        {:error, :no_vehicles_available}
      else
        # 3. Bin-pack deliveries into vehicle loads (greedy by weight)
        sorted_deliveries = Enum.sort_by(deliveries, & &1.weight_kg, :desc)

        {assignments, _} =
          Enum.reduce(sorted_deliveries, {%{}, vehicles}, fn delivery, {loads, remaining_vehicles} ->
            vehicle =
              Enum.find(remaining_vehicles, fn v ->
                current_load = loads |> Map.get(v.id, []) |> Enum.sum_by(& &1.weight_kg)
                current_load + delivery.weight_kg <= v.capacity_kg
              end)

            if is_nil(vehicle) do
              Logger.warning("No vehicle has capacity for delivery #{delivery.id}")
              {loads, remaining_vehicles}
            else
              updated = Map.update(loads, vehicle.id, [delivery], &[delivery | &1])
              {updated, remaining_vehicles}
            end
          end)

        # 4. For each vehicle, build the optimised route (nearest-neighbour)
        routes =
          Enum.map(assignments, fn {vehicle_id, load} ->
            vehicle = Enum.find(vehicles, &(&1.id == vehicle_id))

            ordered =
              Enum.reduce_while(1..length(load), {[depot.coordinates], load}, fn _, {path, remaining} ->
                current = List.last(path)

                nearest =
                  Enum.min_by(remaining, fn d ->
                    DistanceMatrix.distance(current, d.coordinates)
                  end)

                {:cont, {path ++ [nearest.coordinates], List.delete(remaining, nearest)}}
              end)

            {_, sorted_coords} = ordered

            ordered_deliveries =
              Enum.map(sorted_coords, fn coord ->
                Enum.find(load, &(&1.coordinates == coord))
              end)
              |> Enum.reject(&is_nil/1)

            # 5. Compute ETAs for each stop
            {stops_with_eta, _} =
              Enum.reduce(ordered_deliveries, {[], {depot.coordinates, ~T[07:30:00]}}, fn delivery, {stops, {prev_coord, current_time}} ->
                dist_km        = DistanceMatrix.distance(prev_coord, delivery.coordinates)
                travel_min     = trunc(dist_km / @speed_kmh * 60)
                arrival_time   = Time.add(current_time, (travel_min + @loading_time_min) * 60, :second)

                stop = %{
                  delivery:     delivery,
                  eta:          arrival_time,
                  distance_km:  Float.round(dist_km, 2)
                }

                {[stop | stops], {delivery.coordinates, arrival_time}}
              end)

            total_distance =
              stops_with_eta
              |> Enum.sum_by(& &1.distance_km)

            estimated_hours = total_distance / @speed_kmh + length(ordered_deliveries) * @loading_time_min / 60.0

            %{
              vehicle:          vehicle,
              stops:            Enum.reverse(stops_with_eta),
              total_distance_km: Float.round(total_distance, 2),
              estimated_hours:  Float.round(estimated_hours, 1)
            }
          end)

        oversized_routes = Enum.filter(routes, &(&1.estimated_hours > @max_route_hours))

        if oversized_routes != [] do
          Logger.warning("#{length(oversized_routes)} routes exceed max hours — review manually")
        end

        unless dry_run do
          # 6. Assign drivers to routes
          available_drivers = Driver.available_for_depot(depot.id, delivery_date)

          routed =
            Enum.zip(routes, available_drivers)
            |> Enum.map(fn {route, driver} ->
              Map.put(route, :driver, driver)
            end)

          # 7. Persist manifests
          Enum.each(routed, fn route ->
            Manifest.create(%{
              vehicle_id:   route.vehicle.id,
              driver_id:    route.driver.id,
              depot_id:     depot.id,
              delivery_date: delivery_date,
              stops:        route.stops,
              total_km:     route.total_distance_km,
              est_hours:    route.estimated_hours,
              created_at:   DateTime.utc_now()
            })
          end)

          # 8. Notify dispatch
          DispatchNotifier.notify_routes_ready(%{
            depot:        depot.name,
            date:         delivery_date,
            route_count:  length(routed),
            total_stops:  Enum.sum(Enum.map(routed, &length(&1.stops)))
          })

          Logger.info("Routes planned: #{length(routed)} vehicles for #{depot.name}")
          {:ok, routed}
        else
          {:ok, routes}
        end
      end
    end
  end
  # VALIDATION: SMELL END
end
```
