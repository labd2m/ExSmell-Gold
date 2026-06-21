# Annotated Example — Code Smell: Code Organization by Process

| Field | Value |
|---|---|
| **Smell name** | Code organization by process |
| **Expected smell location** | `PricingEngine` module — entire GenServer structure |
| **Affected function(s)** | `compute_price/3`, `apply_tier_pricing/3`, `margin/3`, `markup_price/3` |
| **Short explanation** | Pricing logic consists of pure arithmetic: applying tier thresholds, computing margins and markups from a cost and a rule set supplied by the caller. No mutable state accumulates between calls, no external service is called, and no resource is shared. The GenServer adds process-level serialisation to what is trivially parallel. |

```elixir
defmodule Commerce.PricingEngine do
  use GenServer

  @moduledoc """
  Computes final selling prices from base costs, applying margin rules,
  tier pricing, and promotional overrides. Used by the catalogue service
  when publishing product prices to storefronts.
  """

  # VALIDATION: SMELL START - Code organization by process
  # VALIDATION: This is a smell because every pricing operation is a pure
  # function of cost data and pricing rules passed in by the caller. The
  # GenServer never mutates its state between calls. Bulk catalogue updates
  # (thousands of products) are forced to serialise through this process,
  # adding avoidable latency without any correctness benefit.

  @rounding_precision 2

  ## Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, :ok, opts)
  end

  @doc """
  Computes the final selling price from `cost` using `rules`.
  Rules map: `%{strategy: atom, margin: float, markup: float,
               tier_breaks: list, floor_price: float}`.
  Returns `{:ok, price_map}`.
  """
  def compute_price(pid, cost, rules) do
    GenServer.call(pid, {:compute_price, cost, rules})
  end

  @doc """
  Returns the tiered price for `quantity` units of a product
  given `cost` and a list of `tier_breaks`.
  Tier break: `%{min_qty: int, price_per_unit: float}`.
  """
  def apply_tier_pricing(pid, quantity, cost, tier_breaks) do
    GenServer.call(pid, {:tier_pricing, quantity, cost, tier_breaks})
  end

  @doc "Returns the gross margin percentage for a given `cost` and `price`."
  def margin(pid, cost, price) do
    GenServer.call(pid, {:margin, cost, price})
  end

  @doc "Returns `{:ok, price}` by applying `markup_pct` to `cost`."
  def markup_price(pid, cost, markup_pct) do
    GenServer.call(pid, {:markup, cost, markup_pct})
  end

  @doc "Returns the minimum viable price that achieves `target_margin` from `cost`."
  def price_for_margin(pid, cost, target_margin) do
    GenServer.call(pid, {:price_for_margin, cost, target_margin})
  end

  ## Server Callbacks

  @impl true
  def init(:ok), do: {:ok, %{}}

  @impl true
  def handle_call({:compute_price, cost, rules}, _from, state) do
    base_price =
      case Map.get(rules, :strategy, :margin) do
        :margin ->
          margin = Map.get(rules, :margin, 0.30)
          cost / (1 - margin)

        :markup ->
          markup = Map.get(rules, :markup, 0.50)
          cost * (1 + markup)

        :fixed ->
          Map.get(rules, :fixed_price, cost)
      end

    floor      = Map.get(rules, :floor_price, 0.0)
    final_price = Float.round(max(base_price, floor), @rounding_precision)
    gross_margin = if final_price > 0, do: Float.round((final_price - cost) / final_price * 100, 2), else: 0.0

    result = %{
      cost:         Float.round(cost, @rounding_precision),
      price:        final_price,
      gross_margin: gross_margin,
      strategy:     Map.get(rules, :strategy, :margin)
    }

    {:reply, {:ok, result}, state}
  end

  def handle_call({:tier_pricing, quantity, _cost, tier_breaks}, _from, state) when tier_breaks == [] do
    {:reply, {:error, :no_tier_breaks_defined}, state}
  end

  def handle_call({:tier_pricing, quantity, _cost, tier_breaks}, _from, state) do
    applicable =
      tier_breaks
      |> Enum.filter(fn %{min_qty: min} -> quantity >= min end)
      |> Enum.sort_by(& &1.min_qty, :desc)
      |> List.first()

    result =
      case applicable do
        nil   -> {:error, :no_applicable_tier}
        tier  -> {:ok, Float.round(tier.price_per_unit * quantity, @rounding_precision)}
      end

    {:reply, result, state}
  end

  def handle_call({:margin, cost, price}, _from, state) do
    result =
      if price > 0 do
        {:ok, Float.round((price - cost) / price * 100, @rounding_precision)}
      else
        {:error, :invalid_price}
      end

    {:reply, result, state}
  end

  def handle_call({:markup, cost, markup_pct}, _from, state) do
    price = Float.round(cost * (1 + markup_pct), @rounding_precision)
    {:reply, {:ok, price}, state}
  end

  def handle_call({:price_for_margin, cost, target_margin}, _from, state) do
    result =
      if target_margin >= 1.0 do
        {:error, :invalid_target_margin}
      else
        price = Float.round(cost / (1 - target_margin), @rounding_precision)
        {:ok, price}
      end

    {:reply, result, state}
  end

  # VALIDATION: SMELL END
end
```
