# Annotated Example 33 — Long Parameter List

## Metadata

| Field | Value |
|---|---|
| **Smell name** | Long Parameter List |
| **Expected smell location** | `Fleet.Assignments.assign_vehicle/10` |
| **Affected function(s)** | `assign_vehicle/10` |
| **Explanation** | The function takes 10 individual parameters covering vehicle identity (vehicle_id, license_plate, vehicle_type), driver info (driver_id, driver_license_number), assignment window (start_date, end_date), and operational config (route_id, fuel_card_number, notify_driver). These belong in distinct `%VehicleRef{}`, `%DriverRef{}`, and `%AssignmentConfig{}` structures rather than a flat positional list. |

---

```elixir
# VALIDATION: SMELL START - Long Parameter List
# VALIDATION: This is a smell because `assign_vehicle/10` takes ten individual
# positional parameters. Vehicle-related data (vehicle_id, license_plate,
# vehicle_type), driver-related data (driver_id, driver_license_number),
# the assignment time window (start_date, end_date), and operational options
# (route_id, fuel_card_number, notify_driver) form three clearly distinct
# groups. Passing all ten as positional scalars makes the call site
# difficult to understand and maintain, especially since several string
# arguments sit adjacent to each other.
defmodule Fleet.Assignments do
  @moduledoc """
  Manages the assignment of fleet vehicles to drivers for specific routes
  and time windows, including conflict detection and driver notification.
  """

  require Logger

  alias Fleet.Repo
  alias Fleet.Schemas.VehicleAssignment
  alias Fleet.Schemas.AssignmentLog
  alias Fleet.ConflictChecker
  alias Fleet.FuelCardService
  alias Fleet.Mailer

  @valid_vehicle_types ~w(sedan van truck motorcycle)

  def assign_vehicle(
        vehicle_id,
        license_plate,
        vehicle_type,
        driver_id,
        driver_license_number,
        start_date,
        end_date,
        route_id,
        fuel_card_number,
        notify_driver
      ) do
# VALIDATION: SMELL END
    with :ok <- validate_vehicle_type(vehicle_type),
         :ok <- validate_date_range(start_date, end_date),
         :ok <- validate_license(driver_license_number) do
      case ConflictChecker.check_vehicle(vehicle_id, start_date, end_date) do
        :conflict ->
          Logger.warn("Vehicle #{vehicle_id} already assigned in [#{start_date}, #{end_date}]")
          {:error, :vehicle_unavailable}

        :available ->
          case ConflictChecker.check_driver(driver_id, start_date, end_date) do
            :conflict ->
              {:error, :driver_unavailable}

            :available ->
              assignment_attrs = %{
                vehicle_id: vehicle_id,
                license_plate: license_plate,
                vehicle_type: vehicle_type,
                driver_id: driver_id,
                driver_license_number: driver_license_number,
                start_date: start_date,
                end_date: end_date,
                route_id: route_id,
                fuel_card_number: fuel_card_number,
                status: :active,
                inserted_at: DateTime.utc_now()
              }

              case Repo.insert(VehicleAssignment.changeset(%VehicleAssignment{}, assignment_attrs)) do
                {:ok, assignment} ->
                  Repo.insert!(AssignmentLog.changeset(%AssignmentLog{}, %{
                    assignment_id: assignment.id,
                    action: :created,
                    occurred_at: DateTime.utc_now()
                  }))

                  if fuel_card_number do
                    FuelCardService.link(fuel_card_number, vehicle_id, assignment.id)
                  end

                  if notify_driver do
                    Mailer.notify_driver_assignment(driver_id, assignment)
                  end

                  Logger.info("Vehicle #{vehicle_id} assigned to driver #{driver_id} for route #{route_id}")
                  {:ok, assignment}

                {:error, changeset} ->
                  Logger.error("Assignment failed: #{inspect(changeset.errors)}")
                  {:error, :assignment_failed}
              end
          end
      end
    end
  end

  defp validate_vehicle_type(t) when t in @valid_vehicle_types, do: :ok
  defp validate_vehicle_type(t), do: {:error, {:unknown_vehicle_type, t}}

  defp validate_date_range(start_date, end_date) do
    with {:ok, s} <- Date.from_iso8601(start_date),
         {:ok, e} <- Date.from_iso8601(end_date) do
      cond do
        Date.compare(s, Date.utc_today()) == :lt -> {:error, :start_date_in_past}
        Date.compare(e, s) != :gt -> {:error, :end_before_start}
        true -> :ok
      end
    else
      _ -> {:error, :invalid_date_format}
    end
  end

  defp validate_license(number) do
    if Regex.match?(~r/^[A-Z0-9\-]{6,20}$/i, number || "") do
      :ok
    else
      {:error, :invalid_driver_license}
    end
  end
end
```
