# Code Smell Annotation

- **Smell name:** Large Class (Large Module)
- **Expected smell location:** The entire `FleetManager` module
- **Affected function(s):** `register_vehicle/1`, `assign_driver/2`, `unassign_driver/1`, `schedule_maintenance/2`, `complete_maintenance/2`, `record_fuel_fill/2`, `plan_route/2`, `start_trip/2`, `end_trip/2`, `compute_fuel_efficiency/2`, `fleet_utilization_report/1`
- **Short explanation:** `FleetManager` handles vehicle registration, driver assignments, maintenance scheduling and completion, fuel tracking, route planning, trip lifecycle (start/end), fuel-efficiency metrics, and fleet utilization reporting. These are at least six distinct fleet-management sub-domains that belong in dedicated modules (e.g., `VehicleRegistry`, `DriverAssignment`, `MaintenanceScheduler`, `FuelTracker`, `RouteOptimizer`, `TripManager`, `FleetAnalytics`).

```elixir
# VALIDATION: SMELL START - Large Class (Large Module)
# VALIDATION: This is a smell because FleetManager combines vehicle registration,
# driver assignment, maintenance scheduling, fuel fill recording, route planning,
# trip lifecycle management, fuel efficiency computation, and utilization
# reporting — eight distinct concerns crammed into one large, incoherent module.
defmodule MyApp.FleetManager do
  @moduledoc """
  Comprehensive fleet management: vehicles, driver assignments,
  maintenance, fuel, routes, trips, and analytics.
  """

  require Logger
  import Ecto.Query

  alias MyApp.Repo
  alias MyApp.Fleet.{Vehicle, Driver, DriverAssignment, MaintenanceRecord, FuelRecord,
                     Route, Trip, TripStop}

  @maintenance_interval_km 10_000
  @min_fuel_pct            0.15

  # -------------------------------------------------------------------
  # Vehicle registry
  # -------------------------------------------------------------------

  def register_vehicle(attrs) do
    changeset = Vehicle.changeset(%Vehicle{}, Map.merge(attrs, %{
      status:          :available,
      odometer_km:     attrs[:odometer_km] || 0,
      registered_at:   DateTime.utc_now()
    }))

    case Repo.insert(changeset) do
      {:ok, vehicle} ->
        Logger.info("Vehicle #{vehicle.plate} registered (id: #{vehicle.id})")
        {:ok, vehicle}

      {:error, _} = err ->
        err
    end
  end

  def update_vehicle(vehicle_id, attrs) do
    vehicle = Repo.get!(Vehicle, vehicle_id)
    allowed = Map.take(attrs, [:make, :model, :year, :plate, :vin, :fuel_type, :capacity_kg])
    vehicle |> Vehicle.changeset(allowed) |> Repo.update()
  end

  def decommission_vehicle(vehicle_id) do
    vehicle = Repo.get!(Vehicle, vehicle_id)
    Repo.update!(Vehicle.changeset(vehicle, %{status: :decommissioned, decommissioned_at: DateTime.utc_now()}))
    :ok
  end

  # -------------------------------------------------------------------
  # Driver assignment
  # -------------------------------------------------------------------

  def assign_driver(%Vehicle{} = vehicle, %Driver{} = driver) do
    active = Repo.get_by(DriverAssignment, vehicle_id: vehicle.id, active: true)

    if active do
      {:error, :vehicle_already_assigned}
    else
      Repo.insert!(%DriverAssignment{
        vehicle_id:  vehicle.id,
        driver_id:   driver.id,
        assigned_at: DateTime.utc_now(),
        active:      true
      })

      Repo.update!(Vehicle.changeset(vehicle, %{status: :assigned}))
      :ok
    end
  end

  def unassign_driver(%Vehicle{} = vehicle) do
    case Repo.get_by(DriverAssignment, vehicle_id: vehicle.id, active: true) do
      nil ->
        {:error, :no_active_assignment}

      assignment ->
        Repo.update!(DriverAssignment.changeset(assignment, %{
          active:         false,
          unassigned_at:  DateTime.utc_now()
        }))
        Repo.update!(Vehicle.changeset(vehicle, %{status: :available}))
        :ok
    end
  end

  # -------------------------------------------------------------------
  # Maintenance
  # -------------------------------------------------------------------

  def schedule_maintenance(%Vehicle{} = vehicle, scheduled_date) do
    Repo.insert!(%MaintenanceRecord{
      vehicle_id:     vehicle.id,
      scheduled_date: scheduled_date,
      odometer_at:    vehicle.odometer_km,
      status:         :scheduled
    })

    Repo.update!(Vehicle.changeset(vehicle, %{status: :maintenance_scheduled}))
    :ok
  end

  def complete_maintenance(%MaintenanceRecord{} = record, details) do
    vehicle = Repo.get!(Vehicle, record.vehicle_id)

    Repo.update!(MaintenanceRecord.changeset(record, %{
      status:       :completed,
      completed_at: DateTime.utc_now(),
      cost_cents:   details[:cost_cents],
      notes:        details[:notes],
      next_due_km:  vehicle.odometer_km + @maintenance_interval_km
    }))

    Repo.update!(Vehicle.changeset(vehicle, %{
      status:          :available,
      last_service_km: vehicle.odometer_km,
      next_service_km: vehicle.odometer_km + @maintenance_interval_km
    }))

    :ok
  end

  # -------------------------------------------------------------------
  # Fuel tracking
  # -------------------------------------------------------------------

  def record_fuel_fill(%Vehicle{} = vehicle, attrs) do
    Repo.insert!(%FuelRecord{
      vehicle_id:    vehicle.id,
      liters:        attrs[:liters],
      cost_cents:    attrs[:cost_cents],
      odometer_km:   attrs[:odometer_km],
      station:       attrs[:station],
      recorded_at:   DateTime.utc_now()
    })

    Repo.update!(Vehicle.changeset(vehicle, %{odometer_km: attrs[:odometer_km]}))
    :ok
  end

  def compute_fuel_efficiency(vehicle_id, since) do
    records =
      from(fr in FuelRecord,
        where: fr.vehicle_id == ^vehicle_id and fr.recorded_at >= ^since,
        order_by: [asc: fr.odometer_km]
      )
      |> Repo.all()

    if length(records) < 2 do
      {:error, :insufficient_data}
    else
      first = hd(records)
      last  = List.last(records)

      km_driven      = last.odometer_km - first.odometer_km
      total_liters   = records |> tl() |> Enum.sum(& &1.liters)
      liters_per_100 = if km_driven > 0, do: Float.round(total_liters / km_driven * 100, 2), else: 0.0

      {:ok, %{km_driven: km_driven, total_liters: total_liters, liters_per_100km: liters_per_100}}
    end
  end

  # -------------------------------------------------------------------
  # Route planning
  # -------------------------------------------------------------------

  def plan_route(vehicle_id, stops) when is_list(stops) do
    vehicle = Repo.get!(Vehicle, vehicle_id)

    if vehicle.status != :available do
      {:error, "Vehicle #{vehicle.plate} is not available"}
    else
      route = Repo.insert!(%Route{
        vehicle_id:  vehicle_id,
        status:      :planned,
        planned_at:  DateTime.utc_now(),
        stop_count:  length(stops)
      })

      Enum.with_index(stops, 1)
      |> Enum.each(fn {stop, idx} ->
        Repo.insert!(%TripStop{
          route_id:  route.id,
          sequence:  idx,
          address:   stop[:address],
          latitude:  stop[:lat],
          longitude: stop[:lng],
          eta:       stop[:eta]
        })
      end)

      {:ok, route}
    end
  end

  # -------------------------------------------------------------------
  # Trip lifecycle
  # -------------------------------------------------------------------

  def start_trip(%Route{status: :planned} = route, driver_id) do
    trip = Repo.insert!(%Trip{
      route_id:    route.id,
      driver_id:   driver_id,
      started_at:  DateTime.utc_now(),
      status:      :in_progress
    })

    Repo.update!(Route.changeset(route, %{status: :in_progress}))
    {:ok, trip}
  end

  def start_trip(%Route{status: s}, _), do: {:error, "Cannot start trip from route status #{s}"}

  def end_trip(%Trip{status: :in_progress} = trip, odometer_end) do
    vehicle = get_trip_vehicle(trip)
    km      = odometer_end - vehicle.odometer_km

    Repo.update!(Trip.changeset(trip, %{
      status:       :completed,
      ended_at:     DateTime.utc_now(),
      km_traveled:  km
    }))

    Repo.update!(Vehicle.changeset(vehicle, %{odometer_km: odometer_end}))
    route = Repo.get!(Route, trip.route_id)
    Repo.update!(Route.changeset(route, %{status: :completed}))

    :ok
  end

  def end_trip(_, _), do: {:error, :trip_not_in_progress}

  defp get_trip_vehicle(%Trip{} = trip) do
    route = Repo.get!(Route, trip.route_id)
    Repo.get!(Vehicle, route.vehicle_id)
  end

  # -------------------------------------------------------------------
  # Fleet utilization reporting
  # -------------------------------------------------------------------

  def fleet_utilization_report(since) do
    vehicles = Repo.all(from v in Vehicle, where: v.status != :decommissioned)

    Enum.map(vehicles, fn vehicle ->
      trips =
        from(t in Trip,
          join: r in Route, on: r.id == t.route_id,
          where: r.vehicle_id == ^vehicle.id and t.started_at >= ^since and t.status == :completed
        )
        |> Repo.all()

      km_total = Enum.sum(Enum.map(trips, & &1.km_traveled || 0))

      %{
        vehicle_id:   vehicle.id,
        plate:        vehicle.plate,
        status:       vehicle.status,
        trips:        length(trips),
        km_driven:    km_total
      }
    end)
  end
end
# VALIDATION: SMELL END
```
