```elixir
defmodule Fleet.VehiclePolicy do
  @moduledoc """
  Defines operational rules for each vehicle category in the fleet,
  including fuel cost estimates, load capacity, and licensing requirements.
  """


  @spec fuel_cost_per_km(atom()) :: float()
  def fuel_cost_per_km(:sedan),  do: 0.08
  def fuel_cost_per_km(:van),    do: 0.14
  def fuel_cost_per_km(:truck),  do: 0.22

  @spec capacity_kg(atom()) :: float()
  def capacity_kg(:sedan),  do: 400.0
  def capacity_kg(:van),    do: 1_200.0
  def capacity_kg(:truck),  do: 10_000.0

  @spec requires_cdl?(atom()) :: boolean()
  def requires_cdl?(:sedan),  do: false
  def requires_cdl?(:van),    do: false
  def requires_cdl?(:truck),  do: true


  def assign_vehicle(route, available_vehicles) do
    needed_capacity = route.cargo_kg

    available_vehicles
    |> Enum.filter(fn v -> capacity_kg(v.type) >= needed_capacity end)
    |> Enum.min_by(fn v -> fuel_cost_per_km(v.type) * route.distance_km end, fn -> nil end)
  end

  def driver_eligible?(driver, vehicle_type) do
    not requires_cdl?(vehicle_type) or driver.has_cdl?
  end
end

defmodule Fleet.MaintenanceScheduler do
  @moduledoc """
  Tracks mileage-based maintenance schedules and generates inspection
  checklists for each vehicle type in the fleet.
  """


  @spec service_interval_km(atom()) :: pos_integer()
  def service_interval_km(:sedan), do: 10_000
  def service_interval_km(:van),   do: 15_000
  def service_interval_km(:truck), do: 20_000

  @spec checklist_template(atom()) :: [String.t()]
  def checklist_template(:sedan) do
    ["Oil & filter", "Tyre pressure", "Brake pads", "Windscreen wash", "Lights"]
  end

  def checklist_template(:van) do
    ["Oil & filter", "Tyre pressure", "Brake pads", "Cargo door seals",
     "Reverse sensors", "Roof rack integrity", "Lights"]
  end

  def checklist_template(:truck) do
    ["Oil & filter", "Coolant level", "Tyre pressure and tread", "Air brakes",
     "Fifth wheel coupling", "Trailer lighting", "Mirrors and cameras",
     "Load restraint system", "Emergency equipment"]
  end


  def due_for_service?(vehicle) do
    km_since_last = vehicle.current_odometer - vehicle.last_service_odometer
    km_since_last >= service_interval_km(vehicle.type)
  end

  def generate_work_order(vehicle) do
    %{
      vehicle_id:        vehicle.id,
      registration:      vehicle.registration,
      type:              vehicle.type,
      odometer:          vehicle.current_odometer,
      checklist:         checklist_template(vehicle.type),
      scheduled_date:    Date.utc_today(),
      next_service_due:  vehicle.current_odometer + service_interval_km(vehicle.type)
    }
  end
end

defmodule Fleet.InsuranceManager do
  @moduledoc """
  Determines insurance tier classifications and annual premium estimates
  for fleet vehicles based on vehicle category.
  """


  @spec insurance_tier(atom()) :: atom()
  def insurance_tier(:sedan), do: :standard
  def insurance_tier(:van),   do: :commercial
  def insurance_tier(:truck), do: :heavy_goods

  @spec annual_premium_estimate(atom()) :: float()
  def annual_premium_estimate(:sedan), do: 1_200.0
  def annual_premium_estimate(:van),   do: 2_400.0
  def annual_premium_estimate(:truck), do: 6_800.0


  def fleet_insurance_report(vehicles) do
    Enum.map(vehicles, fn vehicle ->
      %{
        vehicle_id:    vehicle.id,
        registration:  vehicle.registration,
        type:          vehicle.type,
        tier:          insurance_tier(vehicle.type),
        est_premium:   annual_premium_estimate(vehicle.type),
        expires_at:    vehicle.insurance_expires_at
      }
    end)
  end

  def vehicles_expiring_soon(vehicles, within_days \\ 30) do
    cutoff = Date.add(Date.utc_today(), within_days)

    Enum.filter(vehicles, fn v ->
      v.insurance_expires_at != nil and
        Date.compare(v.insurance_expires_at, cutoff) != :gt
    end)
  end
end
```
