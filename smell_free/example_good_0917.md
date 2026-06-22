```elixir
defmodule Shipping.DimensionalWeightCalculator do
  @moduledoc """
  Calculates dimensional (volumetric) weight for parcels using carrier-
  specific divisors. Many carriers bill for the greater of actual weight
  and dimensional weight. This module provides pure calculation functions
  for each supported carrier and a convenience function that returns the
  billable weight automatically.
  """

  @type carrier :: :fedex | :ups | :dhl | :usps
  @type dimensions :: %{length_cm: float(), width_cm: float(), height_cm: float()}
  @type weight_result :: %{
          actual_grams: pos_integer(),
          dimensional_grams: non_neg_integer(),
          billable_grams: non_neg_integer(),
          billing_basis: :actual | :dimensional
        }

  @divisors %{
    fedex: 5_000,
    ups:   5_000,
    dhl:   5_000,
    usps:  166
  }

  @doc """
  Returns a weight result map for `carrier` with actual weight, dimensional
  weight, and the higher of the two as the billable weight.
  """
  @spec calculate(carrier(), pos_integer(), dimensions()) :: weight_result()
  def calculate(carrier, actual_grams, %{length_cm: l, width_cm: w, height_cm: h} = _dims)
      when is_atom(carrier) and is_integer(actual_grams) and actual_grams > 0 do
    divisor = Map.get(@divisors, carrier, 5_000)
    dimensional_grams = round(l * w * h / divisor * 1_000)
    billable = max(actual_grams, dimensional_grams)
    basis = if billable == actual_grams, do: :actual, else: :dimensional

    %{
      actual_grams: actual_grams,
      dimensional_grams: dimensional_grams,
      billable_grams: billable,
      billing_basis: basis
    }
  end

  @doc "Returns the billable weight in grams for the given carrier and parcel."
  @spec billable_grams(carrier(), pos_integer(), dimensions()) :: non_neg_integer()
  def billable_grams(carrier, actual_grams, dims) do
    %{billable_grams: grams} = calculate(carrier, actual_grams, dims)
    grams
  end

  @doc "Returns the dimensional divisor for the given carrier."
  @spec divisor_for(carrier()) :: pos_integer()
  def divisor_for(carrier) when is_atom(carrier) do
    Map.get(@divisors, carrier, 5_000)
  end

  @doc "Returns true when the dimensional weight exceeds the actual weight."
  @spec dimensional_billing?(carrier(), pos_integer(), dimensions()) :: boolean()
  def dimensional_billing?(carrier, actual_grams, dims) do
    %{billing_basis: basis} = calculate(carrier, actual_grams, dims)
    basis == :dimensional
  end

  @doc "Returns the volume in cubic centimetres for the given dimensions."
  @spec volume_cm3(dimensions()) :: float()
  def volume_cm3(%{length_cm: l, width_cm: w, height_cm: h}) do
    l * w * h
  end

  @doc "Returns a comparison of billable weights across all supported carriers."
  @spec compare_carriers(pos_integer(), dimensions()) :: %{carrier() => weight_result()}
  def compare_carriers(actual_grams, dims) when is_integer(actual_grams) do
    Map.new(@divisors, fn {carrier, _} ->
      {carrier, calculate(carrier, actual_grams, dims)}
    end)
  end
end
```
