```elixir
defmodule Billing.OverageCalculator do
  @moduledoc """
  Calculates usage overage charges for metered subscription plans.
  Each plan defines a base quota per billing period and a per-unit rate
  for usage beyond that quota. The calculator applies tiered pricing when
  tiers are configured, falling back to a flat overage rate otherwise.
  All arithmetic is integer-based to avoid rounding errors.
  """

  @type tier :: %{up_to: pos_integer() | :infinity, rate_cents: non_neg_integer()}
  @type plan :: %{
          base_quota: non_neg_integer(),
          flat_rate_cents: non_neg_integer(),
          tiers: [tier()] | nil
        }

  @type overage_result :: %{
          base_units: non_neg_integer(),
          overage_units: non_neg_integer(),
          charge_cents: non_neg_integer(),
          breakdown: [%{units: non_neg_integer(), rate_cents: non_neg_integer(), charge_cents: non_neg_integer()}]
        }

  @doc """
  Calculates the overage charge for `used_units` against `plan`. Returns
  zero charge when usage is within the base quota.
  """
  @spec calculate(plan(), non_neg_integer()) :: overage_result()
  def calculate(%{base_quota: quota} = plan, used_units)
      when is_integer(used_units) and used_units >= 0 do
    overage = max(0, used_units - quota)

    {charge, breakdown} =
      if is_list(plan.tiers) and not Enum.empty?(plan.tiers) do
        tiered_charge(plan.tiers, overage)
      else
        flat_charge(plan.flat_rate_cents, overage)
      end

    %{
      base_units: min(used_units, quota),
      overage_units: overage,
      charge_cents: charge,
      breakdown: breakdown
    }
  end

  @doc "Returns the effective rate in cents per unit for a given overage quantity."
  @spec effective_rate(plan(), non_neg_integer()) :: non_neg_integer()
  def effective_rate(%{tiers: nil, flat_rate_cents: rate}, _overage), do: rate
  def effective_rate(%{tiers: []}, _overage), do: 0

  def effective_rate(%{tiers: tiers}, overage) do
    matching_tier =
      Enum.find(tiers, fn
        %{up_to: :infinity} -> true
        %{up_to: limit} -> overage <= limit
      end)

    case matching_tier do
      nil -> 0
      tier -> tier.rate_cents
    end
  end

  defp flat_charge(rate_cents, overage) do
    charge = overage * rate_cents
    breakdown = [%{units: overage, rate_cents: rate_cents, charge_cents: charge}]
    {charge, breakdown}
  end

  defp tiered_charge(tiers, overage) do
    {total_charge, breakdown, _remaining} =
      Enum.reduce(tiers, {0, [], overage}, fn tier, {charge_acc, lines_acc, remaining} ->
        if remaining == 0 do
          {charge_acc, lines_acc, 0}
        else
          tier_units =
            case tier.up_to do
              :infinity -> remaining
              limit -> min(remaining, limit)
            end

          tier_charge = tier_units * tier.rate_cents
          line = %{units: tier_units, rate_cents: tier.rate_cents, charge_cents: tier_charge}
          {charge_acc + tier_charge, lines_acc ++ [line], remaining - tier_units}
        end
      end)

    {total_charge, Enum.filter(breakdown, fn b -> b.units > 0 end)}
  end
end
```
