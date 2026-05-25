# Annotated Example — Large Module (Large Class)

| Field | Value |
|---|---|
| **Smell name** | Large Module (Large Class) |
| **Expected smell location** | `FleetManager` module (entire module) |
| **Affected functions** | All functions: vehicle registration, maintenance scheduling, driver management, telemetry, and fuel tracking |
| **Short explanation** | `FleetManager` encompasses vehicle registration/decommissioning, maintenance scheduling and history, driver assignment, GPS telemetry recording, and fuel consumption tracking — five entirely distinct fleet management sub-domains in one module. |

```elixir
# VALIDATION: SMELL START - Large Module (Large Class)
# VALIDATION: This is a smell because FleetManager conflates vehicle
# registration, maintenance scheduling, driver management, GPS telemetry,
# and fuel tracking — five separate fleet management concerns — into one
# large non-cohesive module with too many responsibilities.
defmodule FleetManager do
  @moduledoc """
  Manages fleet vehicles, drivers, maintenance, telemetry, and fuel.
  """

  require Logger
  import Ecto.Query

  alias MyApp.Repo
  alias MyApp.Fleet.{
    Vehicle,
    MaintenanceSchedule,
    MaintenanceRecord,
    Driver,
    DriverAssignment,
    TelemetryEvent,
    FuelLog
  }

  @maintenance_alert_days 7
  @speed_alert_kmh 120
  @fuel_efficiency_threshold 12.0

  # --- Vehicle Registration ---

  def register_vehicle(attrs) do
    with {:ok, vehicle} <-
           %Vehicle{}
           |> Vehicle.changeset(attrs)
           |> Repo.insert() do
      Logger.info("Vehicle #{vehicle.id} (#{vehicle.plate}) registered")
      schedule_initial_maintenance(vehicle)
      {:ok, vehicle}
    end
  end

  def update_vehicle(vehicle_id, attrs) do
    Repo.get!(Vehicle, vehicle_id)
    |> Vehicle.changeset(attrs)
    |> Repo.update()
  end

  def decommission_vehicle(vehicle_id, reason) do
    vehicle = Repo.get!(Vehicle, vehicle_id)

    with :ok <- ensure_no_active_assignment(vehicle_id),
         {:ok, updated} <-
           vehicle
           |> Vehicle.changeset(%{
             status: :decommissioned,
             decommission_reason: reason,
             decommissioned_at: DateTime.utc_now()
           })
           |> Repo.update() do
      Logger.info("Vehicle #{vehicle_id} decommissioned: #{reason}")
      {:ok, updated}
    end
  end

  defp ensure_no_active_assignment(vehicle_id) do
    active =
      Repo.exists?(
        from a in DriverAssignment,
          where: a.vehicle_id == ^vehicle_id and a.status == :active
      )

    if active, do: {:error, :vehicle_has_active_assignment}, else: :ok
  end

  # --- Maintenance ---

  defp schedule_initial_maintenance(%Vehicle{id: id, vehicle_type: type}) do
    intervals = maintenance_intervals(type)

    Enum.each(intervals, fn {service, days} ->
      Repo.insert(%MaintenanceSchedule{
        vehicle_id: id,
        service_type: service,
        due_at: DateTime.add(DateTime.utc_now(), days * 86400, :second),
        status: :scheduled
      })
    end)
  end

  defp maintenance_intervals(:truck), do: [oil_change: 90, tire_rotation: 180, inspection: 365]
  defp maintenance_intervals(:van), do: [oil_change: 90, inspection: 180]
  defp maintenance_intervals(_), do: [oil_change: 90, inspection: 365]

  def due_maintenance_alerts do
    threshold = DateTime.add(DateTime.utc_now(), @maintenance_alert_days * 86400, :second)

    Repo.all(
      from m in MaintenanceSchedule,
        where: m.status == :scheduled and m.due_at <= ^threshold,
        preload: [:vehicle]
    )
  end

  def record_maintenance(vehicle_id, service_type, attrs) do
    with {:ok, record} <-
           Repo.insert(%MaintenanceRecord{
             vehicle_id: vehicle_id,
             service_type: service_type,
             performed_at: attrs.performed_at,
             odometer_km: attrs.odometer_km,
             cost: attrs.cost,
             notes: attrs.notes
           }),
         schedule <- Repo.get_by(MaintenanceSchedule, vehicle_id: vehicle_id, service_type: service_type) do
      if schedule do
        next_due = DateTime.add(attrs.performed_at, maintenance_interval_days(service_type) * 86400, :second)

        schedule
        |> MaintenanceSchedule.changeset(%{due_at: next_due})
        |> Repo.update()
      end

      {:ok, record}
    end
  end

  defp maintenance_interval_days(:oil_change), do: 90
  defp maintenance_interval_days(:tire_rotation), do: 180
  defp maintenance_interval_days(_), do: 365

  # --- Driver Management ---

  def register_driver(attrs) do
    %Driver{}
    |> Driver.changeset(attrs)
    |> Repo.insert()
    |> case do
      {:ok, driver} ->
        Logger.info("Driver #{driver.id} registered: #{driver.name}")
        {:ok, driver}

      err ->
        err
    end
  end

  def assign_driver(driver_id, vehicle_id, from_dt, to_dt) do
    with :ok <- ensure_no_active_assignment(vehicle_id),
         :ok <- ensure_driver_available(driver_id, from_dt, to_dt) do
      Repo.insert(%DriverAssignment{
        driver_id: driver_id,
        vehicle_id: vehicle_id,
        from: from_dt,
        to: to_dt,
        status: :active,
        assigned_at: DateTime.utc_now()
      })
    end
  end

  defp ensure_driver_available(driver_id, from_dt, to_dt) do
    conflict =
      Repo.exists?(
        from a in DriverAssignment,
          where:
            a.driver_id == ^driver_id and
              a.status == :active and
              a.from < ^to_dt and
              a.to > ^from_dt
      )

    if conflict, do: {:error, :driver_unavailable}, else: :ok
  end

  def end_assignment(assignment_id) do
    Repo.get!(DriverAssignment, assignment_id)
    |> DriverAssignment.changeset(%{status: :completed, completed_at: DateTime.utc_now()})
    |> Repo.update()
  end

  # --- Telemetry ---

  def ingest_telemetry(vehicle_id, %{lat: lat, lng: lng, speed_kmh: speed, timestamp: ts}) do
    Repo.insert(%TelemetryEvent{
      vehicle_id: vehicle_id,
      latitude: lat,
      longitude: lng,
      speed_kmh: speed,
      recorded_at: ts
    })

    if speed > @speed_alert_kmh do
      Logger.warning("Speed alert: vehicle #{vehicle_id} at #{speed} km/h")
      create_speed_alert(vehicle_id, speed, ts)
    end

    :ok
  end

  defp create_speed_alert(vehicle_id, speed, timestamp) do
    Repo.insert(%MyApp.Fleet.Alert{
      vehicle_id: vehicle_id,
      type: :speed_violation,
      details: %{speed_kmh: speed},
      occurred_at: timestamp
    })
  end

  def vehicle_route(vehicle_id, from_dt, to_dt) do
    Repo.all(
      from t in TelemetryEvent,
        where:
          t.vehicle_id == ^vehicle_id and
            t.recorded_at >= ^from_dt and
            t.recorded_at <= ^to_dt,
        order_by: [asc: t.recorded_at],
        select: %{lat: t.latitude, lng: t.longitude, ts: t.recorded_at, speed: t.speed_kmh}
    )
  end

  # --- Fuel Tracking ---

  def log_fuel(vehicle_id, %{liters: liters, odometer_km: odo, price_per_liter: price, fueled_at: ts}) do
    vehicle = Repo.get!(Vehicle, vehicle_id)

    last_log =
      Repo.one(
        from f in FuelLog,
          where: f.vehicle_id == ^vehicle_id,
          order_by: [desc: f.fueled_at],
          limit: 1
      )

    km_since_last = if last_log, do: odo - last_log.odometer_km, else: 0
    efficiency_km_per_l = if liters > 0 and km_since_last > 0, do: km_since_last / liters, else: nil

    Repo.insert(%FuelLog{
      vehicle_id: vehicle_id,
      liters: liters,
      odometer_km: odo,
      price_per_liter: price,
      total_cost: liters * price,
      km_per_liter: efficiency_km_per_l,
      fueled_at: ts
    })

    if efficiency_km_per_l && efficiency_km_per_l < @fuel_efficiency_threshold do
      Logger.warning("Poor fuel efficiency for vehicle #{vehicle.plate}: #{Float.round(efficiency_km_per_l, 2)} km/L")
    end
  end

  def fuel_consumption_report(vehicle_id, from_date, to_date) do
    Repo.all(
      from f in FuelLog,
        where:
          f.vehicle_id == ^vehicle_id and
            fragment("DATE(?)", f.fueled_at) >= ^from_date and
            fragment("DATE(?)", f.fueled_at) <= ^to_date,
        order_by: [asc: f.fueled_at]
    )
  end
end
# VALIDATION: SMELL END
```
