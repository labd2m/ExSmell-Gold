```elixir
defmodule MyApp.Catalogue.DynamicPricer do
  @moduledoc """
  Adjusts product prices in real time based on configurable demand signals:
  current inventory level, recent sales velocity, and time-of-day factors.
  Adjustments are expressed as basis-point multipliers applied to the base
  price and are capped at configurable floor and ceiling values to prevent
  runaway pricing.

  The module is purely functional. Callers fetch the signals and supply
  them directly, keeping database and cache concerns outside this module.
  """

  @type demand_signal :: %{
          required(:inventory_ratio) => float(),
          required(:velocity_ratio) => float(),
          optional(:time_factor) => float()
        }

  @type pricing_config :: %{
          optional(:floor_bps) => non_neg_integer(),
          optional(:ceiling_bps) => pos_integer(),
          optional(:inventory_weight) => float(),
          optional(:velocity_weight) => float(),
          optional(:time_weight) => float()
        }

  @type dynamic_price :: %{
          base_price_cents: pos_integer(),
          adjusted_price_cents: pos_integer(),
          adjustment_bps: integer(),
          signals: demand_signal()
        }

  @default_config %{
    floor_bps: 7_000,
    ceiling_bps: 15_000,
    inventory_weight: 0.4,
    velocity_weight: 0.4,
    time_weight: 0.2
  }

  @doc """
  Computes the dynamically adjusted price for a product given its base
  price in cents and current `signals`. Returns a `dynamic_price` map
  containing both the adjusted price and a breakdown for transparency.
  """
  @spec price(pos_integer(), demand_signal(), pricing_config()) :: dynamic_price()
  def price(base_price_cents, signals, config \\ %{})
      when is_integer(base_price_cents) and base_price_cents > 0 do
    cfg = Map.merge(@default_config, config)
    adjustment_bps = compute_adjustment(signals, cfg)
    clamped_bps = clamp(adjustment_bps, cfg.floor_bps, cfg.ceiling_bps)
    adjusted = round(base_price_cents * clamped_bps / 10_000)

    %{
      base_price_cents: base_price_cents,
      adjusted_price_cents: max(adjusted, 1),
      adjustment_bps: clamped_bps,
      signals: signals
    }
  end

  @doc "Returns the adjustment in basis points without applying it."
  @spec adjustment_bps(demand_signal(), pricing_config()) :: integer()
  def adjustment_bps(signals, config \\ %{}) do
    cfg = Map.merge(@default_config, config)
    clamp(compute_adjustment(signals, cfg), cfg.floor_bps, cfg.ceiling_bps)
  end

  @spec compute_adjustment(demand_signal(), pricing_config()) :: integer()
  defp compute_adjustment(signals, cfg) do
    inv_score = inventory_score(signals.inventory_ratio)
    vel_score = velocity_score(signals.velocity_ratio)
    time_score = Map.get(signals, :time_factor, 1.0)

    weighted =
      inv_score * cfg.inventory_weight +
        vel_score * cfg.velocity_weight +
        time_score * cfg.time_weight

    round(weighted * 10_000)
  end

  @spec inventory_score(float()) :: float()
  defp inventory_score(ratio) do
    cond do
      ratio <= 0.1 -> 1.5
      ratio <= 0.3 -> 1.2
      ratio <= 0.7 -> 1.0
      true -> 0.85
    end
  end

  @spec velocity_score(float()) :: float()
  defp velocity_score(ratio) do
    cond do
      ratio >= 2.0 -> 1.4
      ratio >= 1.5 -> 1.2
      ratio >= 1.0 -> 1.0
      ratio >= 0.5 -> 0.9
      true -> 0.75
    end
  end

  @spec clamp(integer(), non_neg_integer(), pos_integer()) :: integer()
  defp clamp(value, floor, ceiling) do
    value |> max(floor) |> min(ceiling)
  end
end
```
