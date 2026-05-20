# Annotated Example 36

- **Smell name:** Unrelated multi-clause function
- **Expected smell location:** `FleetOpsHandler.handle/1`
- **Affected function(s):** `handle/1`
- **Short explanation:** `handle/1` processes vehicle service scheduling, driver assignment, and route deviation alerts — three entirely different fleet management concerns — under one multi-clause function, with different stakeholders, data flows, and urgency levels per clause.

```elixir
defmodule FleetOpsHandler do
  @moduledoc """
  Fleet operations handler for the logistics and transport platform.
  Manages vehicle servicing, driver assignment workflows, and
  real-time route deviation alerting.
  """

  alias FleetOpsHandler.{
    ServiceScheduleRequest,
    DriverAssignmentRequest,
    RouteDeviationAlert,
    VehicleStore,
    DriverStore,
    ServiceStore,
    DispatchStore,
    RouteMonitor,
    MaintenanceQueue,
    DispatchNotifier,
    SafetyTeamNotifier
  }

  require Logger

  @doc """
  Handle a fleet operations event.

  Accepts a `%ServiceScheduleRequest{}`, `%DriverAssignmentRequest{}`, or
  `%RouteDeviationAlert{}` and performs the corresponding fleet operation.

  ## Examples

      iex> FleetOpsHandler.handle(%ServiceScheduleRequest{vehicle_id: "VH-001", service_type: :oil_change})
      {:ok, %{service_id: "svc_001", scheduled_at: ~N[2024-07-10 08:00:00]}}

  """
  # VALIDATION: SMELL START - Unrelated multi-clause function
  # VALIDATION: This is a smell because scheduling a vehicle service,
  # assigning a driver to a dispatch, and handling a real-time route
  # deviation alert are completely different fleet operations with different
  # urgency levels (planned maintenance vs HR dispatch vs live safety alert),
  # different actors, and different response time expectations. Grouping
  # them under `handle/1` conflates these unrelated fleet concerns.

  def handle(%ServiceScheduleRequest{
        vehicle_id: vehicle_id,
        service_type: service_type,
        preferred_date: preferred_date,
        mileage: mileage,
        requested_by: requested_by
      }) do
    with {:ok, vehicle} <- VehicleStore.find(vehicle_id),
         :ok <- validate_vehicle_not_decommissioned(vehicle),
         {:ok, slot} <-
           MaintenanceQueue.find_next_available(preferred_date, service_type),
         estimated_duration = estimate_service_duration(service_type),
         {:ok, service} <-
           ServiceStore.create(%{
             vehicle_id: vehicle_id,
             service_type: service_type,
             scheduled_at: slot.starts_at,
             estimated_duration_minutes: estimated_duration,
             mileage_at_booking: mileage,
             requested_by: requested_by,
             status: :scheduled
           }),
         :ok <- VehicleStore.update(vehicle_id, %{next_service_date: slot.starts_at}),
         :ok <- DispatchNotifier.send_service_scheduled(requested_by, vehicle, service) do
      Logger.info("Vehicle #{vehicle_id} scheduled for #{service_type} on #{slot.starts_at}")
      {:ok, %{service_id: service.id, scheduled_at: service.scheduled_at}}
    end
  end

  # handle driver assignment to an active dispatch
  def handle(%DriverAssignmentRequest{
        dispatch_id: dispatch_id,
        driver_id: driver_id,
        vehicle_id: vehicle_id,
        assigned_by: dispatcher_id
      }) do
    with {:ok, dispatch} <- DispatchStore.find(dispatch_id),
         {:ok, driver} <- DriverStore.find(driver_id),
         {:ok, vehicle} <- VehicleStore.find(vehicle_id),
         :ok <- validate_driver_available(driver),
         :ok <- validate_vehicle_operational(vehicle),
         :ok <- validate_driver_licensed_for(driver, vehicle.category),
         {:ok, updated} <-
           DispatchStore.update(dispatch_id, %{
             driver_id: driver_id,
             vehicle_id: vehicle_id,
             assigned_at: DateTime.utc_now(),
             assigned_by: dispatcher_id,
             status: :assigned
           }),
         :ok <- DriverStore.update(driver_id, %{status: :on_duty, current_dispatch_id: dispatch_id}),
         :ok <- DispatchNotifier.send_assignment_to_driver(driver.device_token, updated) do
      Logger.info("Driver #{driver_id} assigned to dispatch #{dispatch_id} with vehicle #{vehicle_id}")
      {:ok, updated}
    end
  end

  # handle route deviation alert from GPS tracking system
  def handle(%RouteDeviationAlert{
        vehicle_id: vehicle_id,
        dispatch_id: dispatch_id,
        current_lat: lat,
        current_lng: lng,
        deviation_km: deviation_km,
        detected_at: detected_at
      })
      when deviation_km > 0 do
    severity = classify_deviation_severity(deviation_km)

    with {:ok, dispatch} <- DispatchStore.find(dispatch_id),
         {:ok, vehicle} <- VehicleStore.find(vehicle_id),
         :ok <-
           RouteMonitor.record_deviation(%{
             dispatch_id: dispatch_id,
             vehicle_id: vehicle_id,
             lat: lat,
             lng: lng,
             deviation_km: deviation_km,
             severity: severity,
             detected_at: detected_at
           }),
         :ok <- DispatchNotifier.notify_deviation(dispatch.assigned_by, vehicle, deviation_km, severity),
         :ok <- maybe_alert_safety_team(severity, vehicle_id, dispatch_id, deviation_km) do
      Logger.warning(
        "Route deviation #{severity} for vehicle #{vehicle_id} on dispatch #{dispatch_id}: #{deviation_km}km off-route"
      )

      {:ok, %{severity: severity, deviation_km: deviation_km}}
    end
  end

  # VALIDATION: SMELL END

  defp validate_vehicle_not_decommissioned(%{status: :decommissioned}),
    do: {:error, :vehicle_decommissioned}

  defp validate_vehicle_not_decommissioned(_), do: :ok

  defp validate_driver_available(%{status: :available}), do: :ok
  defp validate_driver_available(%{status: s}), do: {:error, {:driver_not_available, s}}

  defp validate_vehicle_operational(%{status: :operational}), do: :ok
  defp validate_vehicle_operational(%{status: s}), do: {:error, {:vehicle_not_operational, s}}

  defp validate_driver_licensed_for(driver, category) do
    if category in driver.license_categories do
      :ok
    else
      {:error, {:driver_not_licensed_for_category, category}}
    end
  end

  defp estimate_service_duration(:oil_change), do: 60
  defp estimate_service_duration(:tyre_rotation), do: 45
  defp estimate_service_duration(:full_inspection), do: 180
  defp estimate_service_duration(_), do: 90

  defp classify_deviation_severity(km) when km < 2, do: :low
  defp classify_deviation_severity(km) when km < 10, do: :medium
  defp classify_deviation_severity(_), do: :high

  defp maybe_alert_safety_team(:high, vehicle_id, dispatch_id, deviation_km) do
    SafetyTeamNotifier.alert_major_deviation(vehicle_id, dispatch_id, deviation_km)
  end

  defp maybe_alert_safety_team(_, _, _, _), do: :ok
end
```
