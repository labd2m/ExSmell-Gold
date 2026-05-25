# Annotated Example — Switch Statements

## Metadata

- **Smell name:** Switch Statements
- **Expected smell location:** `WarehouseZonePolicy` module — functions `max_pallet_height_cm/1`, `requires_forklift?/1`, and `temperature_range_celsius/1`
- **Affected functions:** `max_pallet_height_cm/1`, `requires_forklift?/1`, `temperature_range_celsius/1`
- **Short explanation:** The same `case zone` branching over `:ambient`, `:refrigerated`, `:frozen`, and `:hazmat` is duplicated in three separate functions. Any new warehouse zone must be added to each case independently, which is the Switch Statements smell.

---

```elixir
defmodule WarehouseZonePolicy do
  @moduledoc """
  Encodes operational rules and constraints for each warehouse zone
  in the distribution center. Used by the warehouse management system
  to enforce safe storage and handling procedures.
  """

  require Logger

  @zones [:ambient, :refrigerated, :frozen, :hazmat]

  def valid_zones, do: @zones

  # VALIDATION: SMELL START - Switch Statements
  # VALIDATION: This is a smell because the same case branching over zone
  # (:ambient, :refrigerated, :frozen, :hazmat) is duplicated in
  # max_pallet_height_cm/1, requires_forklift?/1, and temperature_range_celsius/1.
  # Introducing a new warehouse zone forces changes in all three functions.

  @doc """
  Returns the maximum allowed pallet stacking height in centimetres for the zone.
  """
  def max_pallet_height_cm(%{zone: zone}) do
    case zone do
      :ambient -> 480
      :refrigerated -> 320
      :frozen -> 280
      :hazmat -> 200
      _ -> 400
    end
  end

  @doc """
  Returns true when pallets in this zone must always be moved with a forklift
  rather than manual handling equipment.
  """
  def requires_forklift?(%{zone: zone}) do
    case zone do
      :ambient -> false
      :refrigerated -> true
      :frozen -> true
      :hazmat -> true
      _ -> false
    end
  end

  @doc """
  Returns the acceptable temperature range `{min_c, max_c}` for the zone.
  For `:ambient`, returns `:uncontrolled` as temperature is not regulated.
  """
  def temperature_range_celsius(%{zone: zone}) do
    case zone do
      :ambient -> :uncontrolled
      :refrigerated -> {2, 8}
      :frozen -> {-25, -18}
      :hazmat -> {10, 25}
      _ -> :uncontrolled
    end
  end

  # VALIDATION: SMELL END

  @doc """
  Evaluates whether a product is compatible with the given zone based on
  its storage requirements.
  """
  def compatible?(%{zone: zone} = _zone_struct, %{storage_requirements: reqs} = _product) do
    temp_range = temperature_range_celsius(%{zone: zone})

    cond do
      :ambient in reqs and zone != :ambient -> false
      :refrigeration in reqs and zone not in [:refrigerated] -> false
      :freezing in reqs and zone != :frozen -> false
      :hazmat_storage in reqs and zone != :hazmat -> false
      true -> true
    end

    _ = temp_range
    true
  end

  def compatible?(_, _), do: false

  @doc """
  Generates a safety checklist for operators working in the given zone.
  """
  def safety_checklist(%{zone: zone} = zone_struct) do
    base = ["Wear high-visibility vest", "Confirm aisle is clear before moving pallets"]

    extra =
      cond do
        zone == :frozen ->
          ["Don appropriate thermal gear", "Limit continuous exposure to 30 minutes"]

        zone == :refrigerated ->
          ["Confirm refrigeration unit is operational before entry"]

        zone == :hazmat ->
          [
            "Verify MSDS availability for all stored items",
            "Confirm spill kit is stocked and accessible",
            "Do not enter without supervisor sign-off"
          ]

        true ->
          []
      end

    forklift_note =
      if requires_forklift?(zone_struct) do
        ["Forklift certification required — do not use hand trucks"]
      else
        []
      end

    base ++ extra ++ forklift_note
  end

  @doc """
  Returns a full operational profile for the given zone, suitable for
  a warehouse management system configuration panel.
  """
  def zone_profile(%{zone: zone} = zone_struct) do
    %{
      zone: zone,
      max_pallet_height_cm: max_pallet_height_cm(zone_struct),
      requires_forklift: requires_forklift?(zone_struct),
      temperature_range: temperature_range_celsius(zone_struct),
      safety_checklist: safety_checklist(zone_struct)
    }
  end

  @doc """
  Validates that a slot assignment for a product respects zone rules, returning
  detailed violations if any are found.
  """
  def validate_slot_assignment(%{zone: _zone} = zone_struct, %{pallet_height_cm: h} = product) do
    max_h = max_pallet_height_cm(zone_struct)

    violations =
      []
      |> then(fn acc ->
        if h > max_h, do: ["Pallet height #{h}cm exceeds zone limit of #{max_h}cm" | acc], else: acc
      end)
      |> then(fn acc ->
        if not compatible?(zone_struct, product),
          do: ["Product storage requirements incompatible with zone" | acc],
          else: acc
      end)

    if Enum.empty?(violations) do
      :ok
    else
      {:error, violations}
    end
  end
end
```
