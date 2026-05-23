```elixir
defmodule Logistics.RouteOptimizer do
  @moduledoc """
  Builds and assigns optimized daily delivery routes for warehouse dispatch operations.
  """

  alias Logistics.{Delivery, RouteStop, RoutePlan, Driver, Repo, EventBus}
  require Logger

  @max_stops_per_driver 25
  @max_weight_per_vehicle_kg 500.0
  @zone_cluster_radius_km 15

  def build_daily_route(warehouse_id, date) do
    Logger.info("Building routes for warehouse=#{warehouse_id} date=#{date}")

    # --- Load pending deliveries ---
    deliveries =
      Delivery
      |> Delivery.pending_for_date(date)
      |> Delivery.for_warehouse(warehouse_id)
      |> Repo.all()
      |> Repo.preload(:recipient)

    if Enum.empty?(deliveries) do
      Logger.info("No deliveries to route for #{date}")
      {:ok, []}
    else
      # --- Cluster by postal zone (first 3 chars of postcode) ---
      clustered =
        Enum.group_by(deliveries, fn d ->
          String.slice(d.recipient.postcode || "", 0, 3)
        end)

      # --- Load available drivers for the day ---
      available_drivers =
        Driver
        |> Driver.available_on(date)
        |> Driver.for_warehouse(warehouse_id)
        |> Repo.all()

      if Enum.empty?(available_drivers) do
        {:error, :no_drivers_available}
      else
        # --- Assign zone clusters to drivers ---
        zone_list = Map.keys(clustered)
        driver_count = length(available_drivers)

        driver_assignments =
          zone_list
          |> Enum.with_index()
          |> Enum.reduce(%{}, fn {zone, idx}, acc ->
            driver = Enum.at(available_drivers, rem(idx, driver_count))
            Map.update(acc, driver.id, [zone], &[zone | &1])
          end)

        # --- Build route plans per driver ---
        route_plans =
          Enum.map(available_drivers, fn driver ->
            zones = Map.get(driver_assignments, driver.id, [])
            stops = Enum.flat_map(zones, &Map.get(clustered, &1, []))

            # Apply stop count cap
            stops = Enum.take(stops, @max_stops_per_driver)

            # Apply weight cap
            {selected_stops, _} =
              Enum.reduce(stops, {[], 0.0}, fn delivery, {selected, weight_acc} ->
                new_weight = weight_acc + (delivery.weight_kg || 0.0)

                if new_weight <= @max_weight_per_vehicle_kg do
                  {[delivery | selected], new_weight}
                else
                  {selected, weight_acc}
                end
              end)

            # Greedy ordering: sort by postcode proximity
            ordered_stops =
              selected_stops
              |> Enum.reverse()
              |> Enum.sort_by(fn d -> d.recipient.postcode end)

            {driver, ordered_stops}
          end)

        # --- Persist route plans ---
        persisted_plans =
          Enum.map(route_plans, fn {driver, stops} ->
            {:ok, plan} =
              Repo.insert(RoutePlan.changeset(%RoutePlan{}, %{
                warehouse_id: warehouse_id,
                driver_id: driver.id,
                scheduled_date: date,
                status: :planned,
                stop_count: length(stops)
              }))

            Enum.with_index(stops, 1) |> Enum.each(fn {delivery, position} ->
              Repo.insert!(%RouteStop{
                route_plan_id: plan.id,
                delivery_id: delivery.id,
                position: position,
                estimated_arrival: nil
              })
            end)

            # --- Notify driver ---
            EventBus.publish("route.assigned", %{
              driver_id: driver.id,
              route_plan_id: plan.id,
              date: date,
              stop_count: length(stops)
            })

            Logger.info("Route plan #{plan.id} assigned to driver #{driver.id} with #{length(stops)} stops")
            plan
          end)

        {:ok, persisted_plans}
      end
    end
  end

  def mark_completed(route_plan_id) do
    case Repo.get(RoutePlan, route_plan_id) do
      nil  -> {:error, :not_found}
      plan -> plan |> RoutePlan.changeset(%{status: :completed}) |> Repo.update()
    end
  end
end
```
