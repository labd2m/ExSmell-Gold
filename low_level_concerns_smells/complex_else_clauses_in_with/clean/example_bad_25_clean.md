```elixir
defmodule Fleet.VehicleDispatcher do
  alias Fleet.{Repo, TripRequest, Vehicle, Driver, DispatchRules, Assignment, TelematicsClient}

  require Logger

  @max_driver_hours_daily 10

  def assign_vehicle(trip_request_id, dispatcher_id, opts \\ []) do
    preferred_vehicle_id = Keyword.get(opts, :vehicle_id)

    with {:ok, trip} <- fetch_open_trip_request(trip_request_id),
         {:ok, vehicle} <- resolve_vehicle(trip, preferred_vehicle_id),
         {:ok, driver} <- resolve_available_driver(vehicle),
         :ok <- DispatchRules.validate(trip, vehicle, driver),
         {:ok, assignment} <- create_assignment(trip, vehicle, driver, dispatcher_id) do
      TelematicsClient.push_assignment(vehicle.telematics_id, assignment)

      Logger.info(
        "Vehicle #{vehicle.id} (driver=#{driver.id}) assigned to trip #{trip_request_id} " <>
          "by dispatcher #{dispatcher_id}"
      )

      {:ok, %{assignment_id: assignment.id, vehicle: vehicle, driver: driver}}
    else
      {:error, :trip_not_found} ->
        Logger.warning("Trip request #{trip_request_id} not found")
        {:error, :trip_not_found}

      {:error, :trip_not_open} ->
        Logger.warning("Trip request #{trip_request_id} is not in an open state")
        {:error, :trip_not_assignable}

      {:error, :vehicle_not_found} ->
        Logger.warning("Requested vehicle not found for trip #{trip_request_id}")
        {:error, :vehicle_unavailable}

      {:error, :vehicle_unavailable} ->
        Logger.warning("No available vehicle found for trip #{trip_request_id}")
        {:error, :vehicle_unavailable}

      {:error, :vehicle_type_mismatch} ->
        Logger.warning("Vehicle type does not match trip requirements for #{trip_request_id}")
        {:error, :vehicle_unsuitable}

      {:error, :driver_not_found} ->
        Logger.warning("No driver assigned to selected vehicle")
        {:error, :driver_unavailable}

      {:error, :driver_off_duty} ->
        Logger.info("Assigned driver is off duty")
        {:error, :driver_unavailable}

      {:error, :driver_hours_exceeded} ->
        Logger.warning("Driver has exceeded #{@max_driver_hours_daily}h daily limit")
        {:error, :driver_hours_limit}

      {:error, :zone_restriction} ->
        Logger.warning("Zone restriction applies to this trip assignment")
        {:error, :dispatch_rule_violation}

      {:error, :cargo_incompatible} ->
        Logger.warning("Vehicle cargo type incompatible with trip #{trip_request_id}")
        {:error, :dispatch_rule_violation}

      {:error, :vehicle_capacity_exceeded} ->
        Logger.warning("Vehicle capacity insufficient for trip #{trip_request_id}")
        {:error, :dispatch_rule_violation}

      {:error, :assignment_failed} ->
        Logger.error("Assignment persistence failed for trip #{trip_request_id}")
        {:error, :persistence_error}
    end
  end

  defp fetch_open_trip_request(trip_request_id) do
    case Repo.get(TripRequest, trip_request_id) do
      nil -> {:error, :trip_not_found}
      %TripRequest{status: status} when status != :open -> {:error, :trip_not_open}
      trip -> {:ok, trip}
    end
  end

  defp resolve_vehicle(%TripRequest{} = trip, nil) do
    case Repo.one(
           from v in Vehicle,
             where: v.status == :available and v.type == ^trip.required_vehicle_type,
             order_by: [asc: v.last_assigned_at],
             limit: 1
         ) do
      nil -> {:error, :vehicle_unavailable}
      vehicle -> {:ok, vehicle}
    end
  end

  defp resolve_vehicle(%TripRequest{required_vehicle_type: type}, vehicle_id) do
    case Repo.get(Vehicle, vehicle_id) do
      nil -> {:error, :vehicle_not_found}
      %Vehicle{status: status} when status != :available -> {:error, :vehicle_unavailable}
      %Vehicle{type: vtype} when vtype != type -> {:error, :vehicle_type_mismatch}
      vehicle -> {:ok, vehicle}
    end
  end

  defp resolve_available_driver(%Vehicle{current_driver_id: nil}), do: {:error, :driver_not_found}

  defp resolve_available_driver(%Vehicle{current_driver_id: driver_id}) do
    case Repo.get(Driver, driver_id) do
      nil -> {:error, :driver_not_found}
      %Driver{on_duty: false} -> {:error, :driver_off_duty}
      %Driver{hours_today: h} when h >= @max_driver_hours_daily -> {:error, :driver_hours_exceeded}
      driver -> {:ok, driver}
    end
  end

  defp create_assignment(trip, vehicle, driver, dispatcher_id) do
    %Assignment{}
    |> Assignment.changeset(%{
      trip_request_id: trip.id,
      vehicle_id: vehicle.id,
      driver_id: driver.id,
      dispatcher_id: dispatcher_id,
      assigned_at: DateTime.utc_now(),
      status: :active
    })
    |> Repo.insert()
    |> case do
      {:ok, a} -> {:ok, a}
      {:error, _} -> {:error, :assignment_failed}
    end
  end
end
```
