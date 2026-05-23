# Annotated Example – Duplicated Code

| Field | Value |
|---|---|
| **Smell name** | Duplicated Code |
| **Expected smell location** | `Logistics.ShippingCalculator.standard_rate/1` and `Logistics.ShippingCalculator.express_rate/1` |
| **Affected functions** | `standard_rate/1`, `express_rate/1` |
| **Short explanation** | Both functions duplicate the logic for computing a package's dimensional weight (length × width × height divided by the DIM factor) and then taking the greater of the actual weight and dimensional weight. If the DIM divisor or rounding logic changes, it must be updated in two places. |

```elixir
defmodule Logistics.ShippingCalculator do
  @moduledoc """
  Calculates shipping rates for packages based on weight, dimensions,
  destination zone, and service level.
  """

  alias Logistics.Package
  alias Logistics.Zone

  @dim_divisor 139
  @standard_base_rate 4.50
  @express_multiplier 2.8
  @oversized_surcharge 15.00
  @residential_surcharge 3.25

  @doc """
  Calculates the standard (ground) shipping rate for a package.
  Returns the total rate in USD as a float.
  """
  def standard_rate(%Package{} = pkg) do
    zone = Zone.for_zip(pkg.destination_zip)

    # VALIDATION: SMELL START - Duplicated Code
    # VALIDATION: This is a smell because the billable_weight calculation —
    # computing dimensional weight via (l * w * h / @dim_divisor) and selecting
    # max(actual_weight, dim_weight) — is duplicated in express_rate/1.
    # A change to the DIM divisor or rounding must be made in both places.
    dim_weight = pkg.length_in * pkg.width_in * pkg.height_in / @dim_divisor
    billable_weight = max(pkg.weight_lbs, dim_weight)
    # VALIDATION: SMELL END

    base = @standard_base_rate * zone.rate_multiplier * billable_weight

    base
    |> apply_surcharges(pkg)
    |> Float.round(2)
  end

  @doc """
  Calculates the express (next-day) shipping rate for a package.
  Returns the total rate in USD as a float.
  """
  def express_rate(%Package{} = pkg) do
    zone = Zone.for_zip(pkg.destination_zip)

    # VALIDATION: SMELL START - Duplicated Code
    # VALIDATION: This is a smell because this billable_weight derivation is
    # a copy of the identical logic in standard_rate/1.
    dim_weight = pkg.length_in * pkg.width_in * pkg.height_in / @dim_divisor
    billable_weight = max(pkg.weight_lbs, dim_weight)
    # VALIDATION: SMELL END

    base = @standard_base_rate * @express_multiplier * zone.rate_multiplier * billable_weight

    base
    |> apply_surcharges(pkg)
    |> Float.round(2)
  end

  @doc """
  Estimates the cheapest available rate across all service levels.
  """
  def cheapest_rate(%Package{} = pkg) do
    [standard_rate(pkg), express_rate(pkg)]
    |> Enum.min()
  end

  @doc """
  Returns a full rate breakdown for all service levels.
  """
  def rate_breakdown(%Package{} = pkg) do
    %{
      standard: standard_rate(pkg),
      express: express_rate(pkg),
      zone: Zone.for_zip(pkg.destination_zip).name
    }
  end

  defp apply_surcharges(rate, %Package{} = pkg) do
    rate
    |> then(fn r -> if oversized?(pkg), do: r + @oversized_surcharge, else: r end)
    |> then(fn r -> if pkg.residential_delivery, do: r + @residential_surcharge, else: r end)
  end

  defp oversized?(%Package{} = pkg) do
    pkg.length_in + 2 * (pkg.width_in + pkg.height_in) > 165 or
      pkg.weight_lbs > 70
  end
end
```
