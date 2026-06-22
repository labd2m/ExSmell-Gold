```elixir
defmodule Catalog.DynamicPricingEngine do
  @moduledoc """
  Adjusts product prices in real-time based on demand signals, inventory
  levels, and competitor price feeds. Pricing decisions are computed by a
  chain of adjustor modules, each applying a bounded percentage change.
  The engine is purely functional; it never writes to the database,
  returning adjusted prices for the caller to persist if desired.
  """

  @type base_price_cents :: pos_integer()
  @type signals :: %{
          demand_score: float(),
          stock_remaining: non_neg_integer(),
          stock_total: pos_integer(),
          competitor_price_cents: pos_integer() | nil,
          hour_of_day: 0..23
        }

  @type adjustment :: %{
          adjustor: String.t(),
          factor: float(),
          reason: String.t()
        }

  @type pricing_result :: %{
          base_cents: base_price_cents(),
          adjusted_cents: non_neg_integer(),
          adjustments: [adjustment()],
          floor_applied: boolean()
        }

  @floor_factor 0.70
  @ceiling_factor 1.50

  @doc """
  Computes the adjusted price for `base_price_cents` given `signals`.
  Applies adjustors in order and clamps the result between the configured
  floor and ceiling multiples of the base price.
  """
  @spec compute(base_price_cents(), signals()) :: pricing_result()
  def compute(base_price_cents, signals)
      when is_integer(base_price_cents) and base_price_cents > 0 and is_map(signals) do
    {final_factor, adjustments} =
      adjustors()
      |> Enum.reduce({1.0, []}, fn {name, adjustor_fn}, {factor_acc, adj_acc} ->
        {delta, reason} = adjustor_fn.(signals)
        new_factor = Float.round(factor_acc * (1.0 + delta), 6)
        adj = %{adjustor: name, factor: 1.0 + delta, reason: reason}
        {new_factor, [adj | adj_acc]}
      end)

    raw_cents = round(base_price_cents * final_factor)
    floor_cents = round(base_price_cents * @floor_factor)
    ceiling_cents = round(base_price_cents * @ceiling_factor)
    clamped = raw_cents |> max(floor_cents) |> min(ceiling_cents)

    %{
      base_cents: base_price_cents,
      adjusted_cents: clamped,
      adjustments: Enum.reverse(adjustments),
      floor_applied: clamped == floor_cents
    }
  end

  @doc "Returns the configured adjustment factor names in evaluation order."
  @spec adjustor_names() :: [String.t()]
  def adjustor_names, do: Enum.map(adjustors(), fn {name, _} -> name end)

  defp adjustors do
    [
      {"demand",      &demand_adjustment/1},
      {"scarcity",    &scarcity_adjustment/1},
      {"competitor",  &competitor_adjustment/1},
      {"peak_hours",  &peak_hours_adjustment/1}
    ]
  end

  defp demand_adjustment(%{demand_score: score}) when score > 0.8,
    do: {0.10, "high demand (score #{Float.round(score, 2)})"}
  defp demand_adjustment(%{demand_score: score}) when score < 0.3,
    do: {-0.05, "low demand (score #{Float.round(score, 2)})"}
  defp demand_adjustment(_), do: {0.0, "normal demand"}

  defp scarcity_adjustment(%{stock_remaining: rem, stock_total: total}) do
    ratio = rem / total
    cond do
      ratio < 0.10 -> {0.15, "critical scarcity (<10% remaining)"}
      ratio < 0.25 -> {0.08, "low stock (<25% remaining)"}
      true         -> {0.0,  "adequate stock"}
    end
  end

  defp competitor_adjustment(%{competitor_price_cents: nil}), do: {0.0, "no competitor data"}
  defp competitor_adjustment(%{competitor_price_cents: comp, demand_score: demand}) do
    _ = demand
    {-0.03, "competitor price factored (#{comp} cents)"}
  end

  defp peak_hours_adjustment(%{hour_of_day: h}) when h in 11..14 or h in 18..21,
    do: {0.05, "peak shopping hours"}
  defp peak_hours_adjustment(_), do: {0.0, "off-peak hours"}
end
```
