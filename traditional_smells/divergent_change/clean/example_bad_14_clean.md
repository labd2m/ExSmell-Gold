```elixir
defmodule Fleet.FleetOperations do
  @moduledoc """
  Manages fleet vehicle registration, GPS tracking, and maintenance scheduling.
  """

  alias Fleet.Repo
  alias Fleet.Vehicles.Vehicle
  alias Fleet.Tracking.LocationRecord
  alias Fleet.Maintenance.MaintenanceJob

  import Ecto.Query
  require Logger



  @doc "Registers a new vehicle into the fleet."
  @spec register_vehicle(map()) :: {:ok, Vehicle.t()} | {:error, Ecto.Changeset.t()}
  def register_vehicle(attrs) do
    required = [:plate, :make, :model, :year, :vin, :fuel_type]

    if Enum.all?(required, &Map.has_key?(attrs, &1)) do
      %Vehicle{}
      |> Vehicle.changeset(Map.merge(attrs, %{status: :active, registered_at: Date.utc_today()}))
      |> Repo.insert()
    else
      {:error, :missing_required_fields}
    end
  end

  @doc "Retires a vehicle from the active fleet (e.g. sold, written off)."
  @spec retire_vehicle(Vehicle.t()) :: {:ok, Vehicle.t()} | {:error, term()}
  def retire_vehicle(%Vehicle{status: :active} = vehicle) do
    vehicle
    |> Vehicle.changeset(%{status: :retired, retired_at: Date.utc_today()})
    |> Repo.update()
  end

  def retire_vehicle(%Vehicle{}), do: {:error, :not_active}

  @doc "Updates administrative details on a vehicle record (e.g. assigned driver, department)."
  @spec update_vehicle_details(Vehicle.t(), map()) ::
          {:ok, Vehicle.t()} | {:error, Ecto.Changeset.t()}
  def update_vehicle_details(%Vehicle{} = vehicle, attrs) do
    allowed = Map.take(attrs, [:assigned_driver_id, :department_id, :notes, :insurance_policy])

    vehicle
    |> Vehicle.changeset(allowed)
    |> Repo.update()
  end


  @doc "Records a GPS location ping for a vehicle."
  @spec record_location(Vehicle.t(), map()) ::
          {:ok, LocationRecord.t()} | {:error, term()}
  def record_location(%Vehicle{id: vehicle_id, status: :active}, %{
        lat: lat,
        lng: lng,
        speed_kmh: speed,
        heading: heading
      }) do
    attrs = %{
      vehicle_id: vehicle_id,
      latitude: lat,
      longitude: lng,
      speed_kmh: speed,
      heading: heading,
      recorded_at: DateTime.utc_now()
    }

    %LocationRecord{}
    |> LocationRecord.changeset(attrs)
    |> Repo.insert()
  end

  def record_location(%Vehicle{status: s}, _), do: {:error, {:vehicle_not_active, s}}

  @doc "Returns the most recent GPS fix for a vehicle."
  @spec get_current_location(Vehicle.t()) :: {:ok, LocationRecord.t()} | {:error, :no_data}
  def get_current_location(%Vehicle{id: vehicle_id}) do
    result =
      LocationRecord
      |> where([l], l.vehicle_id == ^vehicle_id)
      |> order_by([l], desc: l.recorded_at)
      |> limit(1)
      |> Repo.one()

    case result do
      nil -> {:error, :no_data}
      record -> {:ok, record}
    end
  end

  @doc "Returns all location records for a vehicle within a UTC datetime range."
  @spec get_route_history(Vehicle.t(), {DateTime.t(), DateTime.t()}) :: [LocationRecord.t()]
  def get_route_history(%Vehicle{id: vehicle_id}, {from, to}) do
    LocationRecord
    |> where([l], l.vehicle_id == ^vehicle_id and l.recorded_at >= ^from and l.recorded_at <= ^to)
    |> order_by([l], asc: l.recorded_at)
    |> Repo.all()
  end


  @doc "Schedules a maintenance job for a vehicle."
  @spec schedule_maintenance(Vehicle.t(), map()) ::
          {:ok, MaintenanceJob.t()} | {:error, term()}
  def schedule_maintenance(%Vehicle{id: vehicle_id}, %{
        type: type,
        scheduled_for: date,
        description: description
      }) do
    attrs = %{
      vehicle_id: vehicle_id,
      job_type: type,
      scheduled_for: date,
      description: description,
      status: :pending
    }

    %MaintenanceJob{}
    |> MaintenanceJob.changeset(attrs)
    |> Repo.insert()
  end

  @doc "Records the completion of a maintenance job, including technician notes."
  @spec complete_maintenance(MaintenanceJob.t(), map()) ::
          {:ok, MaintenanceJob.t()} | {:error, term()}
  def complete_maintenance(%MaintenanceJob{status: :pending} = job, %{
        technician_id: tech_id,
        notes: notes,
        cost_cents: cost
      }) do
    job
    |> MaintenanceJob.changeset(%{
      status: :completed,
      completed_by: tech_id,
      technician_notes: notes,
      actual_cost_cents: cost,
      completed_at: DateTime.utc_now()
    })
    |> Repo.update()
  end

  def complete_maintenance(%MaintenanceJob{}, _), do: {:error, :not_pending}

  @doc "Lists all vehicles with maintenance jobs overdue or due within 7 days."
  @spec list_due_maintenance() :: [MaintenanceJob.t()]
  def list_due_maintenance do
    cutoff = Date.add(Date.utc_today(), 7)

    MaintenanceJob
    |> where([m], m.status == :pending and m.scheduled_for <= ^cutoff)
    |> order_by([m], asc: m.scheduled_for)
    |> preload(:vehicle)
    |> Repo.all()
  end

end
```
