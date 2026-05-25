# Annotated Example — Speculative Generality

## Metadata

- **Smell name:** Speculative Generality
- **Expected smell location:** `calculate/3` in `Inventory.ReorderCalculator`
- **Affected function(s):** `calculate/3`
- **Short explanation:** The `calculate/3` function accepts a `strategy` keyword option with a default of `:eoq` (Economic Order Quantity). The intent was to let callers choose between multiple reorder strategies (`:eoq`, `:fixed_quantity`, `:min_max`) at runtime. In practice, every call site in the codebase omits the option and relies on `:eoq`. No caller has ever passed a different strategy, making the parameter dead speculative flexibility.

---

```elixir
defmodule Inventory.ReorderCalculator do
  @moduledoc """
  Computes reorder quantities and reorder points for SKUs based on
  consumption history, lead times, and safety stock policies.

  Supports pluggable reorder strategies, defaulting to the Economic
  Order Quantity (EOQ) model.
  """

  alias Inventory.{SKU, ConsumptionHistory, LeadTimeRecord}

  @holding_cost_rate 0.25
  @ordering_cost_default 45.0
  @service_level_z 1.645

  @spec calculate(String.t(), map()) ::
          {:ok, map()} | {:error, atom()}
  # VALIDATION: SMELL START - Speculative Generality
  # VALIDATION: This is a smell because the `strategy:` keyword option with default 
  # `:eoq` was added speculatively to allow different reorder algorithms to be 
  # selected per SKU or caller context. In practice, no call site in the codebase 
  # passes a different strategy — every caller uses `calculate(sku_id, params)` 
  # without the option. The parameter and the dispatch logic are dead speculative 
  # flexibility that inflates the function signature.
  def calculate(sku_id, params, opts \\ []) do
    strategy = Keyword.get(opts, :strategy, :eoq)

    with {:ok, sku} <- SKU.fetch(sku_id),
         {:ok, history} <- ConsumptionHistory.fetch_last_90_days(sku_id),
         {:ok, lead_time} <- LeadTimeRecord.average(sku_id) do
      demand_rate = average_daily_demand(history)
      demand_std_dev = demand_std_dev(history)
      safety_stock = compute_safety_stock(demand_std_dev, lead_time)
      reorder_point = Float.round(demand_rate * lead_time + safety_stock, 0)

      order_quantity =
        case strategy do
          :eoq ->
            annual_demand = demand_rate * 365
            ordering_cost = Map.get(params, :ordering_cost, @ordering_cost_default)
            unit_cost = sku.unit_cost
            holding_cost = unit_cost * @holding_cost_rate
            eoq(annual_demand, ordering_cost, holding_cost)

          :fixed_quantity ->
            Map.fetch!(params, :fixed_quantity)

          :min_max ->
            max_stock = Map.fetch!(params, :max_stock)
            max_stock - reorder_point
        end

      {:ok,
       %{
         sku_id: sku_id,
         strategy: strategy,
         order_quantity: Float.round(order_quantity, 0),
         reorder_point: reorder_point,
         safety_stock: safety_stock,
         average_daily_demand: Float.round(demand_rate, 2),
         average_lead_time_days: lead_time,
         calculated_at: DateTime.utc_now()
       }}
    end
  end
  # VALIDATION: SMELL END

  defp eoq(annual_demand, ordering_cost, holding_cost) do
    :math.sqrt(2 * annual_demand * ordering_cost / holding_cost)
  end

  defp average_daily_demand([]), do: 0.0

  defp average_daily_demand(history) do
    total = Enum.sum(Enum.map(history, & &1.units_consumed))
    total / length(history)
  end

  defp demand_std_dev([]), do: 0.0

  defp demand_std_dev(history) do
    values = Enum.map(history, & &1.units_consumed)
    mean = Enum.sum(values) / length(values)
    variance = Enum.reduce(values, 0.0, fn v, acc -> acc + :math.pow(v - mean, 2) end) / length(values)
    :math.sqrt(variance)
  end

  defp compute_safety_stock(demand_std_dev, lead_time_days) do
    Float.round(@service_level_z * demand_std_dev * :math.sqrt(lead_time_days), 2)
  end
end

defmodule Inventory.ReorderJob do
  alias Inventory.{ReorderCalculator, PurchaseOrderBuilder}

  def run_daily_reorder_check(sku_ids) do
    Enum.each(sku_ids, fn sku_id ->
      case ReorderCalculator.calculate(sku_id, %{}) do
        {:ok, recommendation} ->
          PurchaseOrderBuilder.maybe_create(recommendation)

        {:error, reason} ->
          require Logger
          Logger.error("Reorder calc failed sku=#{sku_id}: #{inspect(reason)}")
      end
    end)
  end
end
```
