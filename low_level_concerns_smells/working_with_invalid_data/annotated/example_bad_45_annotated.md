# Example 45: Warehouse Slotting and Bin Capacity Service - Annotated

## Metadata
- **Smell Name**: Working with invalid data
- **Expected Location**: `Warehouse.SlottingService.assign_bin/4` function
- **Affected Functions**: `assign_bin/4`
- **Explanation**: The function does not validate that `unit_volume` is a number before passing it into multiplication with `quantity` and the subsequent comparison against `bin.remaining_capacity`. Non-numeric values will raise inside the expression rather than at the public boundary.

## Code

```elixir
defmodule Warehouse.SlottingService do
  @moduledoc """
  Manages product-to-bin slot assignments, capacity enforcement,
  pick-path optimisation, and bin replenishment triggers.
  """

  alias Warehouse.{Bin, Product, SlotAssignment, ReplenishmentOrder, PickPath, AuditLog}

  @overflow_zone "OVERFLOW-01"
  @replenishment_threshold_pct 0.20

  def list_available_bins(zone_id, min_capacity \\ 0) do
    with {:ok, bins} <- Bin.list_by_zone(zone_id) do
      available =
        bins
        |> Enum.filter(&(&1.status == :active and &1.remaining_capacity >= min_capacity))
        |> Enum.sort_by(& &1.remaining_capacity, :desc)
        |> Enum.map(&summarize_bin/1)

      {:ok, available}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  # VALIDATION: SMELL START - Working with invalid data
  # VALIDATION: This is a smell because `unit_volume` is used in multiplication
  # VALIDATION: with `quantity` and then compared against `bin.remaining_capacity`
  # VALIDATION: without any validation that it is a numeric type.
  # VALIDATION: If a caller passes a string like "0.35" (e.g., from a CSV import),
  # VALIDATION: the ArithmeticError will appear inside the expression
  # VALIDATION: `unit_volume * quantity` rather than at the boundary of this function.
  def assign_bin(product_id, bin_id, quantity, unit_volume) do
    with {:ok, product} <- Product.get(product_id),
         {:ok, bin} <- Bin.get(bin_id),
         :ok <- validate_bin_available(bin),
         :ok <- validate_product_compatible(product, bin) do

      # No type validation on unit_volume before arithmetic
      required_volume = unit_volume * quantity

      if required_volume > bin.remaining_capacity do
        {:error, :insufficient_bin_capacity}
      else
        assignment = %SlotAssignment{
          id: generate_assignment_id(),
          product_id: product_id,
          bin_id: bin_id,
          quantity: quantity,
          unit_volume: unit_volume,
          total_volume: required_volume,
          assigned_at: DateTime.utc_now(),
          status: :active
        }

        new_remaining = bin.remaining_capacity - required_volume

        {:ok, _} = SlotAssignment.insert(assignment)
        {:ok, _} = Bin.update(bin_id, %{remaining_capacity: new_remaining, product_id: product_id})
        {:ok, _} = AuditLog.record(:bin_assigned, product_id, %{bin_id: bin_id, volume: required_volume})

        if new_remaining / bin.total_capacity < @replenishment_threshold_pct do
          trigger_replenishment(product_id, bin_id)
        end

        {:ok, assignment}
      end
    else
      {:error, reason} -> {:error, reason}
    end
  end
  # VALIDATION: SMELL END

  def vacate_bin(bin_id, reason) do
    with {:ok, bin} <- Bin.get(bin_id),
         {:ok, assignments} <- SlotAssignment.list_active_for_bin(bin_id) do

      Enum.each(assignments, fn a ->
        {:ok, _} = SlotAssignment.update(a.id, %{status: :vacated, vacated_at: DateTime.utc_now()})
      end)

      {:ok, _} = Bin.update(bin_id, %{
        remaining_capacity: bin.total_capacity,
        product_id: nil,
        status: :empty
      })

      {:ok, _} = AuditLog.record(:bin_vacated, bin_id, %{reason: reason, assignments_cleared: length(assignments)})

      {:ok, %{bin_id: bin_id, cleared_assignments: length(assignments)}}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  def consolidate_bins(product_id, zone_id) do
    with {:ok, product} <- Product.get(product_id),
         {:ok, assignments} <- SlotAssignment.list_active_for_product_in_zone(product_id, zone_id) do

      if length(assignments) <= 1 do
        {:ok, :no_consolidation_needed}
      else
        total_quantity = Enum.sum(Enum.map(assignments, & &1.quantity))
        total_volume = Enum.sum(Enum.map(assignments, & &1.total_volume))

        case find_bin_with_capacity(zone_id, total_volume) do
          {:ok, target_bin} ->
            Enum.each(assignments, fn a ->
              {:ok, _} = SlotAssignment.update(a.id, %{status: :consolidated, consolidated_at: DateTime.utc_now()})
              {:ok, _} = Bin.update(a.bin_id, %{remaining_capacity: Bin.get!(a.bin_id).total_capacity, product_id: nil})
            end)

            {:ok, _} = assign_bin(product_id, target_bin.id, total_quantity, product.unit_volume)
            {:ok, %{consolidated_from: length(assignments), target_bin: target_bin.id}}

          {:error, _} ->
            {:error, :no_bin_with_sufficient_capacity}
        end
      end
    else
      {:error, reason} -> {:error, reason}
    end
  end

  def optimise_pick_path(order_id, bin_ids) do
    with {:ok, bins} <- fetch_bins(bin_ids) do
      sorted_bins = Enum.sort_by(bins, fn b -> {b.aisle, b.bay, b.level} end)

      pick_path = %PickPath{
        id: generate_path_id(),
        order_id: order_id,
        stops: Enum.map(sorted_bins, fn b ->
          %{bin_id: b.id, aisle: b.aisle, bay: b.bay, level: b.level, location_code: b.location_code}
        end),
        estimated_distance_m: estimate_path_distance(sorted_bins),
        generated_at: DateTime.utc_now()
      }

      {:ok, _} = PickPath.insert(pick_path)
      {:ok, pick_path}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  def generate_zone_capacity_report(zone_id) do
    with {:ok, bins} <- Bin.list_by_zone(zone_id) do
      total_capacity = Enum.sum(Enum.map(bins, & &1.total_capacity))
      used_capacity = Enum.sum(Enum.map(bins, fn b -> b.total_capacity - b.remaining_capacity end))
      utilisation_pct = if total_capacity > 0, do: used_capacity / total_capacity * 100, else: 0.0

      by_status =
        Enum.group_by(bins, & &1.status)
        |> Enum.map(fn {status, bs} -> {status, length(bs)} end)
        |> Map.new()

      {:ok, %{
        zone_id: zone_id,
        bin_count: length(bins),
        total_capacity_m3: Float.round(total_capacity, 2),
        used_capacity_m3: Float.round(used_capacity, 2),
        utilisation_pct: Float.round(utilisation_pct, 1),
        by_status: by_status,
        generated_at: DateTime.utc_now()
      }}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate_bin_available(%{status: :active}), do: :ok
  defp validate_bin_available(%{status: :maintenance}), do: {:error, :bin_under_maintenance}
  defp validate_bin_available(%{status: :full}), do: {:error, :bin_full}
  defp validate_bin_available(_), do: {:error, :bin_not_available}

  defp validate_product_compatible(product, bin) do
    cond do
      product.hazmat and not bin.hazmat_approved -> {:error, :bin_not_hazmat_approved}
      product.refrigerated and not bin.refrigerated -> {:error, :bin_not_refrigerated}
      product.max_stack_height > bin.height_m -> {:error, :product_too_tall_for_bin}
      true -> :ok
    end
  end

  defp find_bin_with_capacity(zone_id, required_volume) do
    case Bin.find_in_zone_with_capacity(zone_id, required_volume) do
      {:ok, [bin | _]} -> {:ok, bin}
      {:ok, []} -> {:error, :no_suitable_bin}
      error -> error
    end
  end

  defp trigger_replenishment(product_id, bin_id) do
    order = %ReplenishmentOrder{
      id: generate_replenishment_id(),
      product_id: product_id,
      bin_id: bin_id,
      status: :pending,
      triggered_at: DateTime.utc_now()
    }
    ReplenishmentOrder.insert(order)
  end

  defp fetch_bins(bin_ids) do
    results = Enum.map(bin_ids, &Bin.get/1)
    if Enum.any?(results, &match?({:error, _}, &1)) do
      {:error, :some_bins_not_found}
    else
      {:ok, Enum.map(results, fn {:ok, b} -> b end)}
    end
  end

  defp estimate_path_distance(bins) do
    bins
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.sum_by(fn [a, b] -> abs(a.aisle - b.aisle) * 10 + abs(a.bay - b.bay) * 2 end)
  end

  defp summarize_bin(bin) do
    %{id: bin.id, location: bin.location_code, remaining_capacity: bin.remaining_capacity, status: bin.status}
  end

  defp generate_assignment_id, do: "slot_#{:crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)}"
  defp generate_path_id, do: "path_#{:crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)}"
  defp generate_replenishment_id, do: "repl_#{:crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)}"
end
```
