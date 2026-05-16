# Annotated Example 21

## Metadata

- **Smell name:** Accessing non-existent Map/Struct fields
- **Expected smell location:** `Fleet.VehicleDispatcher.dispatch/2`, lines where `job` map keys are accessed dynamically
- **Affected function(s):** `dispatch/2`
- **Short explanation:** `job[:pickup_location]`, `job[:dropoff_location]`, `job[:cargo_weight_kg]`, and `job[:requires_refrigeration]` use dynamic bracket access. When `:cargo_weight_kg` is absent, `nil` flows into vehicle capacity comparison logic, silently matching oversized loads to vehicles that cannot carry them instead of raising a field-missing error.

---

```elixir
defmodule Fleet.VehicleDispatcher do
  @moduledoc """
  Matches incoming transport jobs to available fleet vehicles based on
  cargo requirements, refrigeration needs, and proximity to pickup.
  """

  require Logger

  @fuel_cost_per_km 0.18

  @type vehicle :: %{
          id: String.t(),
          plate: String.t(),
          capacity_kg: float(),
          refrigerated: boolean(),
          current_location: %{lat: float(), lng: float()},
          available: boolean()
        }

  @type dispatch_result :: %{
          job_id: String.t(),
          vehicle_id: String.t(),
          estimated_distance_km: float(),
          estimated_cost: float(),
          dispatched_at: DateTime.t()
        }

  @spec dispatch(map(), list(vehicle())) ::
          {:ok, dispatch_result()} | {:error, String.t()}
  def dispatch(job, available_vehicles) do
    # VALIDATION: SMELL START - Accessing non-existent Map/Struct fields
    # VALIDATION: This is a smell because `job[:pickup_location]`,
    # `job[:dropoff_location]`, `job[:cargo_weight_kg]`, and
    # `job[:requires_refrigeration]` use dynamic bracket access on a plain
    # map. When `:cargo_weight_kg` is absent, `nil` is compared against
    # `vehicle.capacity_kg` inside `capable?/2` via `<=`, which evaluates
    # to `false` in Elixir (nil is not a number), making every vehicle appear
    # incapable rather than raising a clear error about the missing field.
    pickup_location        = job[:pickup_location]
    dropoff_location       = job[:dropoff_location]
    cargo_weight_kg        = job[:cargo_weight_kg]
    requires_refrigeration = job[:requires_refrigeration]
    # VALIDATION: SMELL END

    with :ok <- validate_locations(pickup_location, dropoff_location),
         :ok <- validate_weight(cargo_weight_kg) do
      candidates =
        available_vehicles
        |> Enum.filter(& &1.available)
        |> Enum.filter(&capable?(&1, cargo_weight_kg, requires_refrigeration))
        |> Enum.sort_by(&distance(&1.current_location, pickup_location))

      case candidates do
        [] ->
          {:error, "No available vehicle meets the job requirements"}

        [best | _] ->
          dist = distance(best.current_location, dropoff_location)
          cost = Float.round(dist * @fuel_cost_per_km, 2)

          result = %{
            job_id: Map.get(job, :id, "unknown"),
            vehicle_id: best.id,
            estimated_distance_km: Float.round(dist, 2),
            estimated_cost: cost,
            dispatched_at: DateTime.utc_now()
          }

          Logger.info("Vehicle dispatched",
            job_id: result.job_id,
            vehicle_id: best.id,
            plate: best.plate,
            distance_km: result.estimated_distance_km,
            refrigerated: requires_refrigeration
          )

          {:ok, result}
      end
    end
  end

  # ── Capability check ─────────────────────────────────────────────────────────

  defp capable?(vehicle, cargo_weight_kg, requires_refrigeration) do
    weight_ok = cargo_weight_kg <= vehicle.capacity_kg
    fridge_ok = !requires_refrigeration || vehicle.refrigerated
    weight_ok && fridge_ok
  end

  # ── Distance (Haversine approximation) ───────────────────────────────────────

  defp distance(%{lat: lat1, lng: lng1}, %{lat: lat2, lng: lng2}) do
    r    = 6_371.0
    dlat = :math.pi() / 180 * (lat2 - lat1)
    dlng = :math.pi() / 180 * (lng2 - lng1)

    a =
      :math.sin(dlat / 2) ** 2 +
        :math.cos(:math.pi() / 180 * lat1) *
          :math.cos(:math.pi() / 180 * lat2) *
          :math.sin(dlng / 2) ** 2

    r * 2 * :math.atan2(:math.sqrt(a), :math.sqrt(1 - a))
  end

  defp distance(nil, _), do: :infinity
  defp distance(_, nil), do: :infinity

  # ── Validators ──────────────────────────────────────────────────────────────

  defp validate_locations(nil, _), do: {:error, "Pickup location is required"}
  defp validate_locations(_, nil), do: {:error, "Dropoff location is required"}
  defp validate_locations(_, _),   do: :ok

  defp validate_weight(nil), do: {:error, "Cargo weight is required"}

  defp validate_weight(w) when is_number(w) and w > 0, do: :ok

  defp validate_weight(w),
    do: {:error, "Cargo weight must be a positive number, got: #{inspect(w)}"}
end
```
