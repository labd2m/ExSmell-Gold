# Annotated Example — Switch Statements

## Metadata

- **Smell name:** Switch Statements
- **Expected smell location:** `PackageClassifier` module — functions `handling_instructions/1`, `volumetric_weight_divisor/1`, and `surcharge_label/1`
- **Affected functions:** `handling_instructions/1`, `volumetric_weight_divisor/1`, `surcharge_label/1`
- **Short explanation:** The same `case size_class` branching over `:small`, `:medium`, `:large`, and `:oversized` is duplicated in three separate functions. Adding a new size class requires updating each case block independently, which is the Switch Statements smell.

---

```elixir
defmodule PackageClassifier do
  @moduledoc """
  Classifies inbound and outbound packages by size, applying appropriate
  handling rules, volumetric weight divisors, and carrier surcharge labels
  for the logistics and warehouse management systems.
  """

  require Logger

  @size_classes [:small, :medium, :large, :oversized]

  def valid_size_classes, do: @size_classes

  @doc """
  Classifies a package into a size class based on its longest dimension and weight.
  """
  def classify(%{length_cm: l, width_cm: w, height_cm: h, weight_kg: weight}) do
    longest = max(l, max(w, h))

    cond do
      longest > 120 or weight > 70 -> :oversized
      longest > 60 or weight > 30 -> :large
      longest > 30 or weight > 10 -> :medium
      true -> :small
    end
  end

  # VALIDATION: SMELL START - Switch Statements
  # VALIDATION: This is a smell because the same case branching over size_class
  # (:small, :medium, :large, :oversized) is duplicated in handling_instructions/1,
  # volumetric_weight_divisor/1, and surcharge_label/1. Adding a new size class
  # requires editing all three case blocks independently.

  @doc """
  Returns the list of mandatory handling instructions for packages of the given
  size class, used by warehouse operators during receiving and dispatch.
  """
  def handling_instructions(%{size_class: size_class}) do
    case size_class do
      :small ->
        ["Can be processed at standard sorter belt"]

      :medium ->
        ["Manual scan required", "Route to medium-parcel conveyor"]

      :large ->
        ["Two-person lift required", "Do not stack", "Route to oversized dock"]

      :oversized ->
        ["Forklift required", "Do not stack", "Notify dock supervisor before movement",
         "Route to freight staging area"]

      _ ->
        ["Unknown size class — consult supervisor"]
    end
  end

  @doc """
  Returns the divisor used when computing volumetric (dimensional) weight from
  package dimensions. Different carriers apply different divisors by size tier.
  """
  def volumetric_weight_divisor(%{size_class: size_class}) do
    case size_class do
      :small -> 5_000
      :medium -> 4_000
      :large -> 3_000
      :oversized -> 2_500
      _ -> 5_000
    end
  end

  @doc """
  Returns the carrier surcharge label applied to shipment invoices for the
  given size class.
  """
  def surcharge_label(%{size_class: size_class}) do
    case size_class do
      :small -> nil
      :medium -> "LRG_PKG"
      :large -> "OVERSIZE_1"
      :oversized -> "OVERSIZE_2"
      _ -> nil
    end
  end

  # VALIDATION: SMELL END

  @doc """
  Computes the billable weight for a package, which is the greater of actual
  weight and volumetric weight.
  """
  def billable_weight_kg(
        %{size_class: _size_class} = size_info,
        %{length_cm: l, width_cm: w, height_cm: h, weight_kg: actual}
      ) do
    divisor = volumetric_weight_divisor(size_info)
    volumetric = l * w * h / divisor
    max(actual, Float.round(volumetric, 2))
  end

  @doc """
  Builds the full classification result for a package, including size class,
  handling instructions, billable weight, and surcharge information.
  """
  def full_classification(%{length_cm: _l} = dimensions) do
    size_class = classify(dimensions)
    size_info = %{size_class: size_class}

    billable = billable_weight_kg(size_info, dimensions)
    instructions = handling_instructions(size_info)
    surcharge = surcharge_label(size_info)

    %{
      size_class: size_class,
      actual_weight_kg: dimensions.weight_kg,
      billable_weight_kg: billable,
      handling_instructions: instructions,
      surcharge_code: surcharge,
      has_surcharge: not is_nil(surcharge)
    }
  end

  @doc """
  Processes a batch of packages and returns aggregated classification statistics.
  """
  def classify_batch(packages) when is_list(packages) do
    results = Enum.map(packages, &full_classification/1)

    by_class = Enum.group_by(results, & &1.size_class)

    summary =
      Enum.map(by_class, fn {class, items} ->
        %{
          size_class: class,
          count: length(items),
          surcharge_count: Enum.count(items, & &1.has_surcharge),
          avg_billable_kg:
            items
            |> Enum.map(& &1.billable_weight_kg)
            |> then(fn weights -> Enum.sum(weights) / max(1, length(weights)) end)
            |> Float.round(2)
        }
      end)

    total_surcharge = Enum.count(results, & &1.has_surcharge)
    Logger.info("Classified #{length(packages)} packages; #{total_surcharge} with surcharges.")

    %{
      total: length(packages),
      by_class: summary,
      results: results
    }
  end
end
```
