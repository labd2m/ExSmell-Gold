```elixir
defmodule Fleet.FuelManager do
  @moduledoc """
  Tracks fuel consumption, refuelling events, efficiency calculations,
  and low-fuel alerting for a managed vehicle fleet.
  """

  require Logger

  alias Fleet.Repo
  alias Fleet.Schema.{Vehicle, FuelLog, MaintenanceAlert}
  alias Fleet.Notifications.DispatchPager

  @low_fuel_threshold_pct 0.15
  @efficiency_window_km 500


  @spec record_refuel(Vehicle.t(), float(), float(), float()) ::
          {:ok, FuelLog.t()} | {:error, term()}
  def record_refuel(%Vehicle{} = vehicle, litres_added, price_per_litre, odometer_km)
      when is_float(litres_added) and is_float(price_per_litre) and is_float(odometer_km) do
    with :ok <- validate_fuel_amount(litres_added, vehicle.tank_capacity_litres),
         :ok <- validate_odometer(vehicle, odometer_km) do
      new_level = min(vehicle.current_fuel_litres + litres_added, vehicle.tank_capacity_litres)
      total_cost = Float.round(litres_added * price_per_litre, 2)

      attrs = %{
        vehicle_id: vehicle.id,
        litres_added: litres_added,
        price_per_litre: price_per_litre,
        total_cost: total_cost,
        odometer_km: odometer_km,
        fuel_level_after: new_level,
        refuelled_at: DateTime.utc_now()
      }

      with {:ok, log} <- %FuelLog{} |> FuelLog.changeset(attrs) |> Repo.insert(),
           {:ok, _} <- update_vehicle_fuel(vehicle, new_level, odometer_km) do
        Logger.info("Refuel: vehicle=#{vehicle.id} added=#{litres_added}L new_level=#{new_level}L")
        {:ok, log}
      end
    end
  end

  @spec compute_fuel_efficiency(Vehicle.t(), float(), float()) ::
          {:ok, float()} | {:error, term()}
  def compute_fuel_efficiency(%Vehicle{} = vehicle, km_driven, litres_consumed)
      when is_float(km_driven) and is_float(litres_consumed) do
    cond do
      km_driven <= 0.0 ->
        {:error, {:invalid_km, km_driven}}

      litres_consumed <= 0.0 ->
        {:error, {:invalid_litres, litres_consumed}}

      true ->
        efficiency_l_per_100km = Float.round(litres_consumed / km_driven * 100.0, 2)

        log =
          "Efficiency: vehicle=#{vehicle.id} #{efficiency_l_per_100km} L/100km " <>
            "(#{km_driven}km / #{litres_consumed}L)"

        Logger.debug(log)
        {:ok, efficiency_l_per_100km}
    end
  end

  @spec check_fuel_level(Vehicle.t(), float()) ::
          {:ok, :sufficient} | {:ok, :low} | {:error, term()}
  def check_fuel_level(%Vehicle{} = vehicle, current_litres)
      when is_float(current_litres) do
    if current_litres < 0.0 or current_litres > vehicle.tank_capacity_litres do
      {:error, {:invalid_fuel_level, current_litres, vehicle.tank_capacity_litres}}
    else
      fill_pct = current_litres / vehicle.tank_capacity_litres

      if fill_pct <= @low_fuel_threshold_pct do
        {:ok, :low}
      else
        {:ok, :sufficient}
      end
    end
  end

  @spec schedule_refuel_alert(Vehicle.t(), float()) :: :ok | {:error, term()}
  def schedule_refuel_alert(%Vehicle{} = vehicle, current_litres)
      when is_float(current_litres) do
    with {:ok, :low} <- check_fuel_level(vehicle, current_litres) do
      fill_pct = Float.round(current_litres / vehicle.tank_capacity_litres * 100.0, 1)

      alert_attrs = %{
        vehicle_id: vehicle.id,
        alert_type: :low_fuel,
        message: "Vehicle #{vehicle.plate} at #{fill_pct}% fuel (#{current_litres}L / #{vehicle.tank_capacity_litres}L)",
        severity: :warning,
        created_at: DateTime.utc_now()
      }

      with {:ok, _alert} <- %MaintenanceAlert{} |> MaintenanceAlert.changeset(alert_attrs) |> Repo.insert() do
        DispatchPager.notify(vehicle.assigned_driver_id, alert_attrs.message)
        :ok
      end
    else
      {:ok, :sufficient} -> :ok
      error -> error
    end
  end


  ## Private helpers

  defp validate_fuel_amount(litres, capacity) when litres <= 0.0,
    do: {:error, {:non_positive_fuel_amount, litres}}

  defp validate_fuel_amount(litres, capacity) when litres > capacity,
    do: {:error, {:exceeds_tank_capacity, litres, capacity}}

  defp validate_fuel_amount(_litres, _capacity), do: :ok

  defp validate_odometer(%Vehicle{odometer_km: last_km}, new_km) when new_km < last_km,
    do: {:error, {:odometer_regression, last_km, new_km}}

  defp validate_odometer(_vehicle, _km), do: :ok

  defp update_vehicle_fuel(%Vehicle{} = vehicle, new_level, odometer_km) do
    vehicle
    |> Vehicle.changeset(%{current_fuel_litres: new_level, odometer_km: odometer_km})
    |> Repo.update()
  end
end
```