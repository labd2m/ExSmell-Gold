# Annotated Example — Divergent Change

## Metadata

- **Smell name:** Divergent Change
- **Expected smell location:** `FleetManager` module (entire module)
- **Affected functions:** `register_vehicle/1`, `decommission_vehicle/2`, `plan_route/3`, `optimize_stop_order/1`, `schedule_maintenance/3`, `record_maintenance_completion/2`
- **Explanation:** `FleetManager` bundles vehicle registration/lifecycle, route planning, and maintenance scheduling/tracking — three operationally distinct domains. Vehicle registry rules may change with fleet compliance standards, routing algorithms may change with map data upgrades, and maintenance policies may change with manufacturer service intervals.

---

```elixir
defmodule MyApp.FleetManager do
  @moduledoc """
  Manages the full fleet lifecycle: vehicle registration, route planning,
  and preventive maintenance scheduling.
  """

  alias MyApp.Repo
  alias MyApp.Schemas.{Vehicle, Route, RouteStop, MaintenanceSchedule}
  import Ecto.Query

  # VALIDATION: SMELL START - Divergent Change
  # VALIDATION: This is a smell because vehicle lifecycle management,
  # route planning/optimization, and maintenance scheduling are three
  # independent domains in one module. DOT compliance changes affect
  # registration, routing algorithm improvements affect planning, and
  # OEM service interval changes affect maintenance — all driving
  # unrelated edits to this single module.

  ## ── Vehicle Registry ─────────────────────────────────────────────────────────

  @doc """
  Registers a new vehicle into the fleet with mandatory compliance fields.
  """
  def register_vehicle(attrs) do
    required = [:vin, :make, :model, :year, :plate_number, :payload_kg]
    missing = Enum.reject(required, &Map.has_key?(attrs, &1))

    if missing != [] do
      {:error, {:missing_fields, missing}}
    else
      %Vehicle{}
      |> Vehicle.changeset(Map.merge(attrs, %{status: :active, registered_at: Date.utc_today()}))
      |> Repo.insert()
    end
  end

  @doc """
  Decommissions a vehicle, removing it from active dispatching.
  """
  def decommission_vehicle(%Vehicle{} = vehicle, reason) do
    if Repo.exists?(from r in Route, where: r.vehicle_id == ^vehicle.id and r.status == :in_progress) do
      {:error, :vehicle_on_active_route}
    else
      vehicle
      |> Vehicle.changeset(%{
        status: :decommissioned,
        decommission_reason: reason,
        decommissioned_at: Date.utc_today()
      })
      |> Repo.update()
    end
  end

  @doc """
  Lists all active vehicles optionally filtered by payload capacity.
  """
  def list_active_vehicles(min_payload_kg \\ 0) do
    from(v in Vehicle,
      where: v.status == :active and v.payload_kg >= ^min_payload_kg,
      order_by: [asc: v.plate_number]
    )
    |> Repo.all()
  end

  ## ── Route Planning ───────────────────────────────────────────────────────────

  @doc """
  Plans a new delivery route for a vehicle with a list of stop addresses.
  """
  def plan_route(%Vehicle{} = vehicle, stops, scheduled_date) do
    Repo.transaction(fn ->
      route =
        %Route{}
        |> Route.changeset(%{
          vehicle_id: vehicle.id,
          scheduled_date: scheduled_date,
          status: :planned,
          stop_count: length(stops),
          created_at: DateTime.utc_now()
        })
        |> Repo.insert!()

      ordered = optimize_stop_order(stops)

      Enum.with_index(ordered, 1)
      |> Enum.each(fn {stop, idx} ->
        %RouteStop{}
        |> RouteStop.changeset(%{
          route_id: route.id,
          sequence: idx,
          address: stop.address,
          delivery_window_start: stop[:window_start],
          delivery_window_end: stop[:window_end]
        })
        |> Repo.insert!()
      end)

      route
    end)
  end

  @doc """
  Reorders stops using a nearest-neighbor heuristic to minimize total distance.
  """
  def optimize_stop_order(stops) do
    case stops do
      [] -> []
      [single] -> [single]
      _ ->
        [first | rest] = stops
        nearest_neighbor_sort([first], rest)
    end
  end

  defp nearest_neighbor_sort(ordered, []), do: Enum.reverse(ordered)

  defp nearest_neighbor_sort([current | _] = ordered, remaining) do
    nearest =
      Enum.min_by(remaining, fn stop ->
        haversine_distance(current.lat, current.lng, stop.lat, stop.lng)
      end)

    nearest_neighbor_sort([nearest | ordered], List.delete(remaining, nearest))
  end

  defp haversine_distance(lat1, lng1, lat2, lng2) do
    r = 6_371
    dlat = (lat2 - lat1) * :math.pi() / 180
    dlng = (lng2 - lng1) * :math.pi() / 180
    a = :math.sin(dlat / 2) ** 2 + :math.cos(lat1 * :math.pi() / 180) *
        :math.cos(lat2 * :math.pi() / 180) * :math.sin(dlng / 2) ** 2
    r * 2 * :math.atan2(:math.sqrt(a), :math.sqrt(1 - a))
  end

  ## ── Maintenance Scheduling ───────────────────────────────────────────────────

  @doc """
  Schedules a maintenance event for a vehicle.
  """
  def schedule_maintenance(%Vehicle{} = vehicle, maintenance_type, due_date) do
    %MaintenanceSchedule{}
    |> MaintenanceSchedule.changeset(%{
      vehicle_id: vehicle.id,
      maintenance_type: maintenance_type,
      due_date: due_date,
      status: :scheduled
    })
    |> Repo.insert()
  end

  @doc """
  Records the completion of a scheduled maintenance event.
  """
  def record_maintenance_completion(%MaintenanceSchedule{} = schedule, technician_notes) do
    schedule
    |> MaintenanceSchedule.changeset(%{
      status: :completed,
      technician_notes: technician_notes,
      completed_at: DateTime.utc_now()
    })
    |> Repo.update()
  end

  # VALIDATION: SMELL END
end
```
