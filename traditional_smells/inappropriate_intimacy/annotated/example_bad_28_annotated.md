# Code Smell Example – Annotated

## Metadata

- **Smell name:** Inappropriate Intimacy
- **Expected smell location:** `TripDispatcher.dispatch/2` function
- **Affected function(s):** `TripDispatcher.dispatch/2`
- **Short explanation:** `TripDispatcher.dispatch/2` fetches a `Vehicle` struct and a `Driver` struct and then directly reads their internal fields (`.fuel_level`, `.odometer_km`, `.next_service_due_km`, `.license_classes`, `.hours_driven_today`, `.max_daily_hours`) to decide whether to allow the dispatch. These eligibility constraints are internal to `Vehicle` and `Driver` and should be evaluated by encapsulated functions on those modules rather than being examined directly in this dispatcher.

---

```elixir
defmodule MyApp.Fleet.TripDispatcher do
  @moduledoc """
  Assigns vehicles and drivers to requested trips.
  Enforces vehicle serviceability checks and driver hours-of-service compliance
  before confirming a dispatch.
  """

  alias MyApp.Fleet.{Vehicle, Driver, Trip, DispatchLog}
  alias MyApp.Notifications.DispatchMailer

  @min_fuel_level        0.15
  @service_warning_km    500

  def dispatch(trip_request_id, opts \\ []) do
    with {:ok, request} <- fetch_request(trip_request_id) do
      preferred_vehicle_id = Keyword.get(opts, :vehicle_id)
      preferred_driver_id  = Keyword.get(opts, :driver_id)

      vehicle = preferred_vehicle_id
                |> then(&if(&1, do: Vehicle.fetch(&1), else: Vehicle.best_available(request)))
                |> unwrap_ok()

      driver  = preferred_driver_id
                |> then(&if(&1, do: Driver.fetch(&1), else: Driver.best_available(request)))
                |> unwrap_ok()

      # VALIDATION: SMELL START - Inappropriate Intimacy
      # VALIDATION: This is a smell because dispatch/2 directly reads .fuel_level,
      # .odometer_km, and .next_service_due_km from the Vehicle struct, and
      # .license_classes, .hours_driven_today, and .max_daily_hours from the Driver
      # struct to make eligibility decisions. Vehicle should expose a road_worthy?/1
      # function and Driver should expose a hours_compliant?/1 function; this module
      # should not know the internal fields used to derive those facts.
      fuel_level        = vehicle.fuel_level
      odometer          = vehicle.odometer_km
      next_service_km   = vehicle.next_service_due_km

      license_classes   = driver.license_classes
      hours_today       = driver.hours_driven_today
      max_hours         = driver.max_daily_hours
      # VALIDATION: SMELL END

      trip_duration_est = estimate_hours(request)
      km_to_service     = next_service_km - odometer

      cond do
        fuel_level < @min_fuel_level ->
          {:error, :vehicle_low_fuel}

        km_to_service < @service_warning_km ->
          {:error, :vehicle_service_overdue}

        request.required_license not in license_classes ->
          {:error, :driver_license_mismatch}

        hours_today + trip_duration_est > max_hours ->
          {:error, :driver_hours_exceeded}

        true ->
          confirm_dispatch(request, vehicle, driver)
      end
    end
  end

  def complete(trip_id, completion_data) do
    case Trip.fetch(trip_id) do
      nil  -> {:error, :not_found}
      trip ->
        updated = %{trip |
          status:         :completed,
          completed_at:   DateTime.utc_now(),
          actual_km:      Map.get(completion_data, :km_driven, 0),
          actual_hours:   Map.get(completion_data, :hours, 0)
        }
        Trip.save(updated)
        Vehicle.update_odometer(trip.vehicle_id, updated.actual_km)
        Driver.log_hours(trip.driver_id, updated.actual_hours)
        {:ok, updated}
    end
  end

  def cancel(trip_id, reason) do
    case Trip.fetch(trip_id) do
      nil -> {:error, :not_found}
      %{status: :completed} -> {:error, :already_completed}
      trip ->
        updated = %{trip | status: :cancelled, cancel_reason: reason, cancelled_at: DateTime.utc_now()}
        Trip.save(updated)
        DispatchMailer.deliver_cancellation(updated)
        {:ok, updated}
    end
  end

  def active_trips do
    :ets.tab2list(:trips)
    |> Enum.map(fn {_, t} -> t end)
    |> Enum.filter(&(&1.status == :in_progress))
    |> Enum.sort_by(& &1.dispatched_at)
  end

  # --- Private helpers ---

  defp confirm_dispatch(request, vehicle, driver) do
    trip = %{
      id:           generate_id(),
      request_id:   request.id,
      vehicle_id:   vehicle.id,
      driver_id:    driver.id,
      origin:       request.origin,
      destination:  request.destination,
      status:       :in_progress,
      dispatched_at: DateTime.utc_now()
    }
    Trip.save(trip)
    DispatchLog.record(trip)
    DispatchMailer.deliver_confirmation(trip)
    {:ok, trip}
  end

  defp estimate_hours(%{distance_km: km}), do: km / 80.0
  defp estimate_hours(_), do: 1.0

  defp fetch_request(id) do
    case :ets.lookup(:trip_requests, id) do
      [{_, r}] -> {:ok, r}
      []       -> {:error, :not_found}
    end
  end

  defp unwrap_ok({:ok, v}), do: v
  defp unwrap_ok(v), do: v

  defp generate_id do
    "TRP-" <> (:crypto.strong_rand_bytes(6) |> Base.encode16())
  end
end
```
