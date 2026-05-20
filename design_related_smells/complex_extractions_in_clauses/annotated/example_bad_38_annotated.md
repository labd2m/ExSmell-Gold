# Annotated Example 38 — Complex Extractions in Clauses

## Metadata

| Field                  | Value                                                                                              |
|------------------------|----------------------------------------------------------------------------------------------------|
| **Smell name**         | Complex extractions in clauses                                                                     |
| **Expected location**  | `Fleet.DispatchCoordinator.dispatch_vehicle/1`                                                     |
| **Affected function**  | `dispatch_vehicle/1`                                                                               |
| **Short explanation**  | The function dispatches based on `vehicle_status` (clause selection) and `fuel_level_pct` (guard), while also extracting `vehicle_id`, `driver_id`, `depot_id`, `route_id`, and `cargo_manifest` in every clause head — none of which influence which clause fires. Across three clauses, each carrying seven extractions, the two dispatch-controlling bindings are indistinguishable from the body-only ones without line-by-line inspection. |

---

```elixir
defmodule Fleet.DispatchCoordinator do
  @moduledoc """
  Coordinates vehicle dispatch from depot to assigned routes.
  Validates vehicle readiness, enforces fuel and maintenance policies,
  and emits telemetry events for fleet tracking systems.
  """

  require Logger

  alias Fleet.{
    RouteAssigner,
    MaintenanceChecker,
    FuelManager,
    TelemetryBus,
    DriverNotifier,
    ManifestValidator,
    DispatchLog,
    AuditLog
  }

  @minimum_fuel_pct 20
  @full_fuel_pct 95

  # VALIDATION: SMELL START - Complex extractions in clauses
  # VALIDATION: This is a smell because `vehicle_id`, `driver_id`, `depot_id`,
  # `route_id`, and `cargo_manifest` are destructured in every clause head yet
  # none of them participate in guard evaluation or clause selection.
  # `vehicle_status` selects the clause and `fuel_level_pct` is used in the
  # guards. With three clauses and seven bindings per head, a reader cannot
  # identify the dispatch conditions without carefully scanning every binding
  # in every clause.
  def dispatch_vehicle(%Fleet.Vehicle{
        vehicle_id: vehicle_id,
        driver_id: driver_id,
        depot_id: depot_id,
        route_id: route_id,
        cargo_manifest: cargo_manifest,
        vehicle_status: :ready,
        fuel_level_pct: fuel_level_pct
      })
      when fuel_level_pct >= @minimum_fuel_pct do
    Logger.info(
      "[DispatchCoordinator] Dispatching vehicle #{vehicle_id} from depot #{depot_id} " <>
        "on route #{route_id} (driver: #{driver_id}, fuel: #{fuel_level_pct}%)"
    )

    with :ok <- MaintenanceChecker.assert_roadworthy(vehicle_id),
         {:ok, validated_manifest} <- ManifestValidator.validate(vehicle_id, cargo_manifest),
         {:ok, route} <- RouteAssigner.activate(route_id, vehicle_id, driver_id),
         :ok <- TelemetryBus.register_active(vehicle_id, route.waypoints),
         :ok <- DriverNotifier.send_dispatch_instructions(driver_id, route, validated_manifest),
         :ok <- DispatchLog.record(vehicle_id, :dispatched, %{
                  driver_id: driver_id,
                  depot_id: depot_id,
                  route_id: route_id,
                  fuel_level_pct: fuel_level_pct,
                  cargo_count: length(validated_manifest)
                }),
         :ok <- AuditLog.write(:vehicle_dispatched, driver_id, %{
                  vehicle_id: vehicle_id,
                  route_id: route_id,
                  depot_id: depot_id
                }) do
      Logger.info("[DispatchCoordinator] Vehicle #{vehicle_id} successfully dispatched")
      {:ok, :dispatched, route.id}
    else
      {:error, :maintenance_required} ->
        Logger.warning("[DispatchCoordinator] Vehicle #{vehicle_id} failed roadworthy check")
        {:error, :maintenance_required}

      {:error, :manifest_invalid} = err ->
        Logger.warning("[DispatchCoordinator] Invalid cargo manifest for #{vehicle_id}")
        err

      {:error, reason} ->
        Logger.error("[DispatchCoordinator] Dispatch failed for #{vehicle_id}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  def dispatch_vehicle(%Fleet.Vehicle{
        vehicle_id: vehicle_id,
        driver_id: driver_id,
        depot_id: depot_id,
        route_id: route_id,
        cargo_manifest: _cargo_manifest,
        vehicle_status: :ready,
        fuel_level_pct: fuel_level_pct
      })
      when fuel_level_pct < @minimum_fuel_pct do
    Logger.warning(
      "[DispatchCoordinator] Vehicle #{vehicle_id} has insufficient fuel (#{fuel_level_pct}%). " <>
        "Sending to refuel before dispatch."
    )

    with {:ok, refuel_bay} <- FuelManager.assign_bay(depot_id, vehicle_id),
         :ok <- DriverNotifier.send_refuel_instructions(driver_id, refuel_bay),
         :ok <- DispatchLog.record(vehicle_id, :held_for_refuel, %{
                  driver_id: driver_id,
                  depot_id: depot_id,
                  route_id: route_id,
                  current_fuel_pct: fuel_level_pct,
                  refuel_bay: refuel_bay
                }) do
      {:ok, :refuelling, refuel_bay}
    else
      {:error, reason} ->
        Logger.error("[DispatchCoordinator] Refuel assignment failed for #{vehicle_id}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  def dispatch_vehicle(%Fleet.Vehicle{
        vehicle_id: vehicle_id,
        driver_id: driver_id,
        depot_id: depot_id,
        route_id: route_id,
        cargo_manifest: _cargo_manifest,
        vehicle_status: :maintenance,
        fuel_level_pct: fuel_level_pct
      })
      when fuel_level_pct >= 0 do
    Logger.warning(
      "[DispatchCoordinator] Vehicle #{vehicle_id} is in maintenance. " <>
        "Cannot dispatch on route #{route_id}."
    )

    with {:ok, alt_vehicle_id} <- Fleet.VehiclePool.find_available(depot_id, route_id),
         :ok <- RouteAssigner.reassign(route_id, alt_vehicle_id, driver_id),
         :ok <- DriverNotifier.send_vehicle_swap_notice(driver_id, alt_vehicle_id),
         :ok <- DispatchLog.record(vehicle_id, :dispatch_blocked, %{
                  reason: :maintenance,
                  depot_id: depot_id,
                  route_id: route_id,
                  alternate_vehicle: alt_vehicle_id
                }) do
      {:ok, :reassigned, alt_vehicle_id}
    else
      {:error, :no_available_vehicle} ->
        Logger.error(
          "[DispatchCoordinator] No available vehicle to cover route #{route_id} from depot #{depot_id}"
        )

        {:error, :no_available_vehicle}

      {:error, reason} ->
        {:error, reason}
    end
  end
  # VALIDATION: SMELL END

  def dispatch_vehicle(%Fleet.Vehicle{vehicle_id: id, vehicle_status: status}) do
    Logger.error("[DispatchCoordinator] Unhandled vehicle status '#{status}' for vehicle #{id}")
    {:error, :unhandled_vehicle_status}
  end
end
```
