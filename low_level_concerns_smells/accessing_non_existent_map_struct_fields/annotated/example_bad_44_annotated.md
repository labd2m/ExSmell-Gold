# Code Smell: Accessing Non-Existent Map/Struct Fields

- **Smell name:** Accessing non-existent Map/Struct fields
- **Expected smell location:** `Fleet.VehicleDispatcher.assign_driver/2`, where optional vehicle capability fields are accessed dynamically
- **Affected function(s):** `assign_driver/2`
- **Short explanation:** The function reads `:refrigerated`, `:max_passengers`, and `:wheelchair_accessible` from the vehicle map using bracket access. Absent keys return `nil`, causing capability checks to silently pass instead of raising a data error — a refrigerated cargo requirement can be matched against a vehicle with no such field configured.

```elixir
defmodule Fleet.VehicleDispatcher do
  @moduledoc """
  Assigns drivers to vehicles for scheduled dispatch runs.
  Validates driver licence class against vehicle category,
  enforces special capability requirements (refrigeration,
  accessibility, passenger capacity), and records assignments.
  """

  require Logger

  @licence_hierarchy %{
    A: [:motorcycle],
    B: [:sedan, :suv, :van],
    C: [:truck, :rigid],
    CE: [:truck, :rigid, :articulated]
  }

  @type vehicle :: %{
          id: String.t(),
          plate: String.t(),
          category: atom(),
          fuel_level_pct: non_neg_integer(),
          odometer_km: non_neg_integer(),
          optional(:refrigerated) => boolean(),
          optional(:max_passengers) => pos_integer(),
          optional(:wheelchair_accessible) => boolean(),
          optional(:gps_tracker_id) => String.t()
        }

  @type driver :: %{
          id: String.t(),
          name: String.t(),
          licence_class: atom(),
          active: boolean()
        }

  @type dispatch_requirement :: %{
          requires_refrigeration: boolean(),
          min_passengers: non_neg_integer(),
          requires_accessibility: boolean()
        }

  @spec assign_driver(vehicle(), driver()) ::
          {:ok, map()} | {:error, String.t()}
  def assign_driver(vehicle, driver) do
    with :ok <- check_driver_active(driver),
         :ok <- check_licence(vehicle, driver),
         :ok <- check_fuel(vehicle) do
      record_assignment(vehicle, driver)
    end
  end

  defp check_driver_active(%{active: true}), do: :ok
  defp check_driver_active(driver),
    do: {:error, "driver #{driver.id} is not active"}

  defp check_licence(vehicle, driver) do
    allowed_categories = Map.get(@licence_hierarchy, driver.licence_class, [])

    if vehicle.category in allowed_categories do
      :ok
    else
      {:error,
       "licence class #{driver.licence_class} does not cover vehicle category #{vehicle.category}"}
    end
  end

  defp check_fuel(%{fuel_level_pct: pct}) when pct < 15,
    do: {:error, "fuel level #{pct}% is below dispatch threshold"}
  defp check_fuel(_), do: :ok

  @spec check_capabilities(vehicle(), dispatch_requirement()) ::
          :ok | {:error, [String.t()]}
  def check_capabilities(vehicle, requirement) do
    # VALIDATION: SMELL START - Accessing non-existent Map/Struct fields
    # VALIDATION: This is a smell because `vehicle[:refrigerated]`,
    # `vehicle[:max_passengers]`, and `vehicle[:wheelchair_accessible]` use
    # dynamic bracket access on a plain map. When any of these keys is absent,
    # `nil` is returned silently. The capability checks then treat `nil` as
    # falsy, so a vehicle without a `:refrigerated` key passes a refrigeration
    # requirement check — it cannot be distinguished from a vehicle explicitly
    # configured as non-refrigerated, masking missing fleet configuration data.
    refrigerated          = vehicle[:refrigerated]
    max_passengers        = vehicle[:max_passengers]
    wheelchair_accessible = vehicle[:wheelchair_accessible]
    # VALIDATION: SMELL END

    errors =
      []
      |> then(fn e ->
        if requirement.requires_refrigeration and not refrigerated,
          do: ["vehicle does not support refrigeration" | e], else: e
      end)
      |> then(fn e ->
        if requirement.min_passengers > 0 and (is_nil(max_passengers) or max_passengers < requirement.min_passengers),
          do: ["vehicle capacity #{max_passengers} below required #{requirement.min_passengers}" | e], else: e
      end)
      |> then(fn e ->
        if requirement.requires_accessibility and not wheelchair_accessible,
          do: ["vehicle is not wheelchair accessible" | e], else: e
      end)

    if errors == [], do: :ok, else: {:error, errors}
  end

  defp record_assignment(vehicle, driver) do
    assignment = %{
      assignment_id: generate_id(),
      vehicle_id:    vehicle.id,
      plate:         vehicle.plate,
      driver_id:     driver.id,
      driver_name:   driver.name,
      assigned_at:   DateTime.utc_now(),
      gps_tracker:   vehicle[:gps_tracker_id]
    }

    Logger.info("Driver #{driver.id} assigned to vehicle #{vehicle.id} (#{vehicle.plate})")
    {:ok, assignment}
  end

  @spec release(map()) :: :ok
  def release(assignment) do
    Logger.info("Assignment #{assignment.assignment_id} released at #{DateTime.utc_now()}")
    :ok
  end

  defp generate_id do
    "ASGN-" <> (:crypto.strong_rand_bytes(5) |> Base.encode16())
  end
end
```
