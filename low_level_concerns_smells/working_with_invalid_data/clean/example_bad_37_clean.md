# Example 37: Fleet Management Fuel Tracking

```elixir
defmodule FleetManager.FuelTracker do
  @moduledoc """
  Records fuel fill-ups, computes fuel economy, and tracks fleet
  fuel costs across vehicles, drivers, and depots.
  """

  alias FleetManager.{Vehicle, Driver, FuelRecord, Depot, CostReport}

  @liters_per_gallon 3.78541

  def list_recent_fill_ups(vehicle_id, limit \\ 20) do
    with {:ok, vehicle} <- Vehicle.get(vehicle_id),
         {:ok, records} <- FuelRecord.list_by_vehicle(vehicle_id, limit: limit) do

      enriched =
        Enum.map(records, fn r ->
          %{
            id: r.id,
            date: r.recorded_at,
            liters: r.liters,
            cost_per_liter: r.cost_per_liter,
            total_cost: r.total_cost,
            odometer: r.odometer_reading,
            fuel_economy_l_per_100km: r.fuel_economy
          }
        end)

      {:ok, %{vehicle: vehicle.plate_number, records: enriched}}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  def record_fill_up(vehicle_id, driver_id, odometer_reading, fuel_data) do
    with {:ok, vehicle} <- Vehicle.get(vehicle_id),
         {:ok, driver} <- Driver.get(driver_id),
         {:ok, previous} <- FuelRecord.last_for_vehicle(vehicle_id),
         :ok <- validate_depot(fuel_data.depot_id) do

      distance_driven = odometer_reading - previous.odometer_reading

      liters = fuel_data.liters
      cost_per_liter = fuel_data.cost_per_liter
      total_cost = liters * cost_per_liter

      fuel_economy =
        if distance_driven > 0 do
          liters / distance_driven * 100
        else
          nil
        end

      record = %FuelRecord{
        id: generate_record_id(),
        vehicle_id: vehicle_id,
        driver_id: driver_id,
        odometer_reading: odometer_reading,
        distance_driven: distance_driven,
        liters: liters,
        cost_per_liter: cost_per_liter,
        total_cost: Float.round(total_cost, 2),
        fuel_economy: fuel_economy && Float.round(fuel_economy, 2),
        depot_id: fuel_data.depot_id,
        recorded_at: DateTime.utc_now()
      }

      {:ok, _} = FuelRecord.insert(record)
      {:ok, _} = Vehicle.update_odometer(vehicle_id, odometer_reading)

      maybe_flag_anomaly(record, vehicle)

      {:ok, record}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  def monthly_cost_report(depot_id, year, month) do
    with {:ok, depot} <- Depot.get(depot_id),
         {:ok, records} <- FuelRecord.list_by_depot_and_month(depot_id, year, month) do

      by_vehicle =
        records
        |> Enum.group_by(& &1.vehicle_id)
        |> Enum.map(fn {vehicle_id, recs} ->
          total_liters = Enum.sum(Enum.map(recs, & &1.liters))
          total_cost = Enum.sum(Enum.map(recs, & &1.total_cost))
          total_distance = Enum.sum(Enum.map(recs, & &1.distance_driven))
          avg_economy = if total_distance > 0, do: total_liters / total_distance * 100, else: nil

          %{
            vehicle_id: vehicle_id,
            fill_up_count: length(recs),
            total_liters: Float.round(total_liters, 2),
            total_cost: Float.round(total_cost, 2),
            total_distance_km: total_distance,
            avg_fuel_economy: avg_economy && Float.round(avg_economy, 2)
          }
        end)

      fleet_total = Enum.sum(Enum.map(by_vehicle, & &1.total_cost))

      report = %CostReport{
        depot_id: depot_id,
        period: "#{year}-#{String.pad_leading("#{month}", 2, "0")}",
        vehicles: by_vehicle,
        fleet_total_cost: Float.round(fleet_total, 2),
        generated_at: DateTime.utc_now()
      }

      {:ok, report}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  def compute_fleet_fuel_economy(depot_id, days_back \\ 30) do
    cutoff = DateTime.add(DateTime.utc_now(), -days_back * 86_400, :second)

    with {:ok, records} <- FuelRecord.list_by_depot_since(depot_id, cutoff) do
      records_with_distance = Enum.filter(records, &(&1.distance_driven > 0))

      overall =
        if Enum.empty?(records_with_distance) do
          nil
        else
          total_liters = Enum.sum(Enum.map(records_with_distance, & &1.liters))
          total_km = Enum.sum(Enum.map(records_with_distance, & &1.distance_driven))
          Float.round(total_liters / total_km * 100, 2)
        end

      {:ok, %{depot_id: depot_id, days_back: days_back, fleet_avg_l_per_100km: overall}}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  def flag_high_consumption_vehicles(depot_id, threshold_l_per_100km) do
    with {:ok, records} <- FuelRecord.list_by_depot_since(depot_id, thirty_days_ago()) do
      vehicle_economies =
        records
        |> Enum.filter(&(&1.fuel_economy != nil))
        |> Enum.group_by(& &1.vehicle_id)
        |> Enum.map(fn {vid, recs} ->
          avg = Enum.sum(Enum.map(recs, & &1.fuel_economy)) / length(recs)
          {vid, Float.round(avg, 2)}
        end)

      flagged =
        vehicle_economies
        |> Enum.filter(fn {_, avg} -> avg > threshold_l_per_100km end)
        |> Enum.map(fn {vid, avg} -> %{vehicle_id: vid, avg_economy: avg} end)

      {:ok, flagged}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp maybe_flag_anomaly(record, vehicle) do
    cond do
      record.fuel_economy && record.fuel_economy > vehicle.expected_economy * 1.3 ->
        :telemetry.execute([:fleet, :fuel, :anomaly], %{economy: record.fuel_economy}, %{
          vehicle_id: vehicle.id,
          record_id: record.id
        })

      record.liters > vehicle.tank_capacity ->
        :telemetry.execute([:fleet, :fuel, :overfill], %{liters: record.liters}, %{
          vehicle_id: vehicle.id
        })

      true ->
        :ok
    end
  end

  defp validate_depot(depot_id) do
    case Depot.get(depot_id) do
      {:ok, _} -> :ok
      {:error, _} -> {:error, :invalid_depot}
    end
  end

  defp thirty_days_ago do
    DateTime.add(DateTime.utc_now(), -30 * 86_400, :second)
  end

  defp generate_record_id do
    "fuel_#{:crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)}"
  end
end
```
