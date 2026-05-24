```elixir
defmodule Logistics.DeliveryAssigner do
  @moduledoc """
  Assigns pending delivery tasks to available drivers based on
  vehicle suitability, zone proximity, and current workload.
  """

  require Logger

  alias Logistics.{Driver, Vehicle, DeliveryTask, Assignment, ZoneMap}
  alias Repo

  @assignment_timeout_minutes 5
  @max_assignment_attempts 3

  def assign(task_id, opts \\ []) do
    with {:ok, task} <- DeliveryTask.fetch(task_id),
         {:ok, drivers} <- Driver.list_available() do
      case find_best_driver(task, drivers, opts) do
        {:ok, driver} ->
          create_assignment(task, driver)

        {:error, :no_driver} ->
          Logger.warning("No driver found for task #{task_id}")
          {:error, :no_available_driver}
      end
    end
  end

  defp find_best_driver(task, drivers, opts) do
    required_zone = task.pickup_zone
    required_weight_kg = task.total_weight_kg
    requires_refrigeration = task.temperature_controlled

    eligible =
      Enum.filter(drivers, fn driver ->
        with true <- driver.status == :available,
             true <- driver.current_zone == required_zone or
                      ZoneMap.adjacent?(driver.current_zone, required_zone),
             {:ok, vehicle} <- Vehicle.fetch(driver.vehicle_id),
             true <- vehicle.load_capacity_kg >= required_weight_kg,
             true <- not requires_refrigeration or vehicle.refrigerated,
             true <- not past_shift_end?(driver.shift_ends_at) do
          true
        else
          _ -> false
        end
      end)

    case eligible do
      [] -> {:error, :no_driver}
      candidates -> {:ok, hd(rank_drivers(candidates, task))}
    end
  end

  defp rank_drivers(drivers, task) do
    Enum.sort_by(drivers, fn driver ->
      zone_distance = ZoneMap.distance(driver.current_zone, task.pickup_zone)

      current_load = Assignment.active_count_for_driver(driver.id)
      load_ratio = current_load / max(driver.max_parcels, 1)

      {:ok, vehicle} = Vehicle.fetch(driver.vehicle_id)

      eco_bonus =
        if vehicle.fuel_type in [:electric, :hybrid], do: -1, else: 0

      zone_distance * 10 + load_ratio * 5 + eco_bonus
    end)
  end

  defp past_shift_end?(nil), do: false

  defp past_shift_end?(shift_ends_at) do
    DateTime.compare(DateTime.utc_now(), shift_ends_at) == :gt
  end

  defp create_assignment(task, driver) do
    assignment = %Assignment{
      task_id: task.id,
      driver_id: driver.id,
      assigned_at: DateTime.utc_now(),
      status: :pending_acceptance,
      expires_at: DateTime.add(DateTime.utc_now(), @assignment_timeout_minutes * 60, :second)
    }

    case Repo.insert(assignment) do
      {:ok, saved} ->
        Logger.info("Task #{task.id} assigned to driver #{driver.id}")
        notify_driver(driver, saved)
        {:ok, saved}

      {:error, changeset} ->
        Logger.error("Assignment insert failed: #{inspect(changeset.errors)}")
        {:error, :persistence_failed}
    end
  end

  defp notify_driver(driver, assignment) do
    Logistics.DriverNotifier.push(driver.id, %{
      type: :new_assignment,
      assignment_id: assignment.id,
      expires_at: assignment.expires_at
    })
  end

  def expire_stale_assignments do
    now = DateTime.utc_now()

    Assignment
    |> Assignment.pending_expired_query(now)
    |> Repo.all()
    |> Enum.each(fn a ->
      a
      |> Assignment.changeset(%{status: :expired})
      |> Repo.update()

      Logger.info("Assignment #{a.id} expired")
    end)
  end
end
```
