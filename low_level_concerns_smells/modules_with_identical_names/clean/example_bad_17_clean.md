```elixir
# ── file: lib/fleet/vehicle.ex ────────────────────────────────────────────────

defmodule Fleet.Vehicle do
  @moduledoc """
  Manages vehicle registration and core telemetry data ingestion.
  Handles new vehicle onboarding into the fleet management system.
  """

  alias Fleet.{Telematics, InsuranceRegistry, MaintenanceScheduler, Repo}

  @valid_fuel_types [:diesel, :petrol, :electric, :hybrid, :hydrogen]
  @valid_categories [:sedan, :suv, :van, :truck, :motorcycle, :bus]

  @type t :: %__MODULE__{
          id: String.t(),
          vin: String.t(),
          registration_plate: String.t(),
          make: String.t(),
          model: String.t(),
          year: pos_integer(),
          fuel_type: atom(),
          category: atom(),
          capacity_kg: pos_integer() | nil,
          odometer_km: non_neg_integer(),
          status: :available | :in_use | :maintenance | :retired,
          driver_id: String.t() | nil,
          depot_id: String.t(),
          registered_at: DateTime.t()
        }

  defstruct [
    :id,
    :vin,
    :registration_plate,
    :make,
    :model,
    :year,
    :fuel_type,
    :category,
    :capacity_kg,
    :driver_id,
    :depot_id,
    :registered_at,
    odometer_km: 0,
    status: :available
  ]

  @spec register(map()) :: {:ok, t()} | {:error, term()}
  def register(attrs) do
    with :ok <- validate_vin(attrs[:vin]),
         :ok <- validate_fuel_type(attrs[:fuel_type]),
         :ok <- validate_category(attrs[:category]),
         :ok <- check_vin_unique(attrs[:vin]),
         {:ok, insurance} <- InsuranceRegistry.verify(attrs[:vin]) do
      vehicle = %__MODULE__{
        id: generate_id(),
        vin: attrs[:vin],
        registration_plate: attrs[:registration_plate],
        make: attrs[:make],
        model: attrs[:model],
        year: attrs[:year],
        fuel_type: attrs[:fuel_type],
        category: attrs[:category],
        capacity_kg: attrs[:capacity_kg],
        depot_id: attrs[:depot_id],
        registered_at: DateTime.utc_now()
      }

      Repo.insert(:vehicles, vehicle)
      Telematics.register_device(vehicle, attrs[:telematics_id])
      MaintenanceScheduler.initialise(vehicle)

      {:ok, vehicle}
    end
  end

  @spec update_odometer(String.t(), non_neg_integer()) :: {:ok, map()} | {:error, term()}
  def update_odometer(vehicle_id, new_km) do
    with {:ok, vehicle} <- Repo.fetch(:vehicles, vehicle_id) do
      if new_km < vehicle.odometer_km do
        {:error, :odometer_cannot_decrease}
      else
        updated = Repo.update(:vehicles, vehicle_id, %{odometer_km: new_km})
        {:ok, updated}
      end
    end
  end

  @spec retire(String.t()) :: {:ok, map()} | {:error, term()}
  def retire(vehicle_id) do
    with {:ok, vehicle} <- Repo.fetch(:vehicles, vehicle_id),
         :ok <- validate_not_in_use(vehicle) do
      updated = Repo.update(:vehicles, vehicle_id, %{status: :retired})
      {:ok, updated}
    end
  end

  defp validate_vin(vin) when is_binary(vin) and byte_size(vin) == 17, do: :ok
  defp validate_vin(_), do: {:error, :invalid_vin}

  defp validate_fuel_type(f) when f in @valid_fuel_types, do: :ok
  defp validate_fuel_type(_), do: {:error, :invalid_fuel_type}

  defp validate_category(c) when c in @valid_categories, do: :ok
  defp validate_category(_), do: {:error, :invalid_category}

  defp check_vin_unique(vin) do
    case Repo.get_by(:vehicles, vin: vin) do
      nil -> :ok
      _ -> {:error, :vin_already_registered}
    end
  end

  defp validate_not_in_use(%{status: :in_use}), do: {:error, :vehicle_in_use}
  defp validate_not_in_use(_), do: :ok

  defp generate_id, do: :crypto.strong_rand_bytes(10) |> Base.encode16(case: :lower)
end


# ── file: lib/fleet/vehicle_assignments.ex ───────────────────────────────────

defmodule Fleet.Vehicle do
  @moduledoc """
  Handles driver-vehicle assignment, route dispatch, and availability tracking.
  Used by the dispatch console and mobile driver app backend.
  """

  alias Fleet.{Driver, Route, Repo, AuditLog, Notifier}

  @spec assign_driver(String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def assign_driver(vehicle_id, driver_id) do
    with {:ok, vehicle} <- Repo.fetch(:vehicles, vehicle_id),
         {:ok, driver} <- Driver.fetch(driver_id),
         :ok <- validate_vehicle_available(vehicle),
         :ok <- Driver.validate_licensed(driver, vehicle.category) do
      updated_vehicle = Repo.update(:vehicles, vehicle_id, %{
        driver_id: driver_id,
        status: :in_use,
        assigned_at: DateTime.utc_now()
      })

      AuditLog.write(:vehicle_assigned, %{
        vehicle_id: vehicle_id,
        driver_id: driver_id
      })

      Notifier.notify_driver(driver, :vehicle_assigned, updated_vehicle)

      {:ok, updated_vehicle}
    end
  end

  @spec unassign_driver(String.t()) :: {:ok, map()} | {:error, term()}
  def unassign_driver(vehicle_id) do
    with {:ok, vehicle} <- Repo.fetch(:vehicles, vehicle_id),
         :ok <- validate_has_driver(vehicle) do
      updated_vehicle = Repo.update(:vehicles, vehicle_id, %{
        driver_id: nil,
        status: :available,
        assigned_at: nil
      })

      AuditLog.write(:vehicle_unassigned, %{
        vehicle_id: vehicle_id,
        previous_driver_id: vehicle.driver_id
      })

      {:ok, updated_vehicle}
    end
  end

  @spec dispatch(String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def dispatch(vehicle_id, route_id) do
    with {:ok, vehicle} <- Repo.fetch(:vehicles, vehicle_id),
         {:ok, route} <- Route.fetch(route_id),
         :ok <- validate_driver_assigned(vehicle) do
      AuditLog.write(:vehicle_dispatched, %{vehicle_id: vehicle_id, route_id: route_id})
      Notifier.notify_driver(vehicle.driver_id, :dispatched, route)
      {:ok, %{vehicle: vehicle, route: route, dispatched_at: DateTime.utc_now()}}
    end
  end

  defp validate_vehicle_available(%{status: :available}), do: :ok
  defp validate_vehicle_available(_), do: {:error, :vehicle_not_available}

  defp validate_has_driver(%{driver_id: nil}), do: {:error, :no_driver_assigned}
  defp validate_has_driver(_), do: :ok

  defp validate_driver_assigned(%{driver_id: nil}), do: {:error, :no_driver_assigned}
  defp validate_driver_assigned(_), do: :ok
end
```
