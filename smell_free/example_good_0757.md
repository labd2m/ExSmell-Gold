```elixir
defmodule MyApp.Supply.ProcurementOptimiser do
  @moduledoc """
  Generates optimal purchase order recommendations for replenishing
  low-stock SKUs. For each SKU below its reorder point the optimiser
  calculates an economic order quantity (EOQ) based on demand rate,
  holding cost, and fixed order cost. Results are returned as a ranked
  list of order recommendations ready for buyer review.

  All calculation is purely functional with no process or I/O.
  """

  @type sku_data :: %{
          required(:sku) => String.t(),
          required(:current_stock) => non_neg_integer(),
          required(:reorder_point) => pos_integer(),
          required(:demand_per_day) => float(),
          required(:unit_cost_cents) => pos_integer(),
          required(:holding_cost_rate) => float(),
          required(:order_fixed_cost_cents) => pos_integer(),
          required(:lead_time_days) => pos_integer()
        }

  @type recommendation :: %{
          sku: String.t(),
          recommended_quantity: pos_integer(),
          estimated_cost_cents: pos_integer(),
          days_of_stock_on_hand: float(),
          urgency: :immediate | :soon | :planned
        }

  @doc """
  Returns purchase order recommendations for all SKUs in `inventory`
  that are at or below their reorder point, sorted by urgency and then
  by estimated total cost descending.
  """
  @spec recommend([sku_data()]) :: [recommendation()]
  def recommend(inventory) when is_list(inventory) do
    inventory
    |> Enum.filter(&needs_reorder?/1)
    |> Enum.map(&build_recommendation/1)
    |> Enum.sort_by(&{urgency_rank(&1.urgency), -&1.estimated_cost_cents})
  end

  @doc """
  Computes the Economic Order Quantity for a single SKU.
  Returns 1 when input parameters would produce a non-positive result.
  """
  @spec eoq(sku_data()) :: pos_integer()
  def eoq(%{
        demand_per_day: d,
        order_fixed_cost_cents: s,
        unit_cost_cents: c,
        holding_cost_rate: h
      }) do
    annual_demand = d * 365
    annual_holding = c * h

    if annual_demand > 0 and annual_holding > 0 do
      quantity = :math.sqrt(2 * annual_demand * s / annual_holding)
      max(round(quantity), 1)
    else
      1
    end
  end

  @spec needs_reorder?(sku_data()) :: boolean()
  defp needs_reorder?(sku), do: sku.current_stock <= sku.reorder_point

  @spec build_recommendation(sku_data()) :: recommendation()
  defp build_recommendation(sku) do
    quantity = eoq(sku)
    cost = quantity * sku.unit_cost_cents
    days_on_hand = if sku.demand_per_day > 0, do: sku.current_stock / sku.demand_per_day, else: 999.0
    urgency = classify_urgency(days_on_hand, sku.lead_time_days)

    %{
      sku: sku.sku,
      recommended_quantity: quantity,
      estimated_cost_cents: cost,
      days_of_stock_on_hand: Float.round(days_on_hand, 1),
      urgency: urgency
    }
  end

  @spec classify_urgency(float(), pos_integer()) :: :immediate | :soon | :planned
  defp classify_urgency(days_on_hand, lead_time_days) do
    cond do
      days_on_hand <= lead_time_days -> :immediate
      days_on_hand <= lead_time_days * 2 -> :soon
      true -> :planned
    end
  end

  @spec urgency_rank(:immediate | :soon | :planned) :: non_neg_integer()
  defp urgency_rank(:immediate), do: 0
  defp urgency_rank(:soon), do: 1
  defp urgency_rank(:planned), do: 2
end
```
