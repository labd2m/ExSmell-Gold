```elixir
defmodule Logistics.DispatchSummaryBuilder do
  @moduledoc """
  Produces dispatch summary documents for fleet coordinators.
  Each summary lists the driver assignments for a given depot and shift,
  including load details, stop counts, and estimated completion times.
  Summaries are printed and handed to the shift supervisor at dispatch.
  """

  alias Logistics.{DepotShift, DriverAssignment, Driver, Vehicle, Stop}

  @max_payload_warning_pct  0.90
  @km_per_litre_estimate    10.0

  # ------------------------------------------------------------------
  # Public API
  # ------------------------------------------------------------------

  @doc """
  Builds a complete dispatch summary for the given depot shift.
  """
  @spec build(String.t()) :: map()
  def build(shift_id) do
    shift       = DepotShift.get!(shift_id)
    assignments = DepotShift.list_assignments(shift)
    supervisor  = DepotShift.get_supervisor(shift)

    %{
      shift_id:        shift.id,
      depot_code:      shift.depot_code,
      shift_date:      shift.date,
      shift_start:     shift.start_time,
      shift_end:       shift.end_time,
      supervisor_name: supervisor.full_name,
      supervisor_badge: supervisor.badge_number,
      total_drivers:   length(assignments),
      total_stops:     sum_stops(assignments),
      loads:           Enum.map(assignments, &format_driver_load/1),
      generated_at:    DateTime.utc_now()
    }
  end

  # ------------------------------------------------------------------
  # Private helpers
  # ------------------------------------------------------------------

  defp format_driver_load(assignment) do
    driver            = DriverAssignment.get_driver(assignment)
    vehicle           = DriverAssignment.get_vehicle(assignment)
    stops             = DriverAssignment.list_stops(assignment)
    total_payload_kg  = DriverAssignment.total_payload_kg(assignment)
    est_duration_min  = DriverAssignment.estimated_duration(assignment)

    stop_count        = length(stops)
    first_stop        = List.first(stops)
    last_stop         = List.last(stops)

    payload_pct =
      if vehicle.max_payload_kg && vehicle.max_payload_kg > 0 do
        total_payload_kg / vehicle.max_payload_kg
      else
        0.0
      end

    est_km           = Stop.total_distance_km(stops)
    est_fuel_litres  = Float.round(est_km / @km_per_litre_estimate, 1)

    %{
      assignment_id:     assignment.id,
      route_code:        assignment.route_code,
      driver_name:       Driver.display_name(driver),
      driver_licence:    driver.licence_number,
      vehicle_plate:     vehicle.registration_plate,
      vehicle_type:      vehicle.vehicle_type,
      max_payload_kg:    vehicle.max_payload_kg,
      total_payload_kg:  Float.round(total_payload_kg, 2),
      payload_utilisation_pct: Float.round(payload_pct * 100, 1),
      overload_warning:  payload_pct >= @max_payload_warning_pct,
      stop_count:        stop_count,
      first_stop:        Stop.short_label(first_stop),
      last_stop:         Stop.short_label(last_stop),
      start_time:        assignment.start_time,
      est_duration_min:  est_duration_min,
      est_km:            Float.round(est_km, 1),
      est_fuel_litres:   est_fuel_litres,
      priority:          assignment.priority_flag
    }
  end

  defp sum_stops(assignments) do
    Enum.reduce(assignments, 0, fn assignment, acc ->
      acc + length(DriverAssignment.list_stops(assignment))
    end)
  end
end
```
