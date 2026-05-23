# Code Smell Example – Annotated

- **Smell:** Feature Envy
- **Expected smell location:** `Inventory.ReplenishmentPlanner.evaluate_variant/1`
- **Affected function(s):** `evaluate_variant/1`
- **Explanation:** `evaluate_variant/1` calls `ProductVariant.get_supplier/1`, `ProductVariant.average_daily_demand/1`, `ProductVariant.lead_time_days/1`, `ProductVariant.safety_stock/1`, and `ProductVariant.reorder_quantity/1`, plus reads many struct fields from the variant directly. `ReplenishmentPlanner` only contributes the final comparison logic. The function envies `ProductVariant` and belongs there.

```elixir
defmodule Inventory.ReplenishmentPlanner do
  @moduledoc """
  Identifies SKUs that have fallen below their reorder point and
  generates purchase-order recommendations for the procurement team.
  Runs as a nightly scheduled task triggered by the job scheduler.
  """

  alias Inventory.{StockLedger, ProductVariant, PurchaseRecommendation}
  alias Procurement.{Supplier, PurchaseOrder}

  @demand_window_days    30
  @safety_stock_factor   1.5
  @low_supplier_score    40

  # ------------------------------------------------------------------
  # Public API
  # ------------------------------------------------------------------

  @doc """
  Scans all active variants and returns a list of `%PurchaseRecommendation{}`
  structs for those that need replenishment.
  """
  @spec run() :: [PurchaseRecommendation.t()]
  def run() do
    ProductVariant.stream_active()
    |> Stream.map(&evaluate_variant/1)
    |> Stream.reject(&is_nil/1)
    |> Enum.to_list()
  end

  @doc """
  Generates and persists purchase orders from a list of recommendations.
  """
  @spec create_purchase_orders([PurchaseRecommendation.t()]) ::
          {:ok, [PurchaseOrder.t()]} | {:error, term()}
  def create_purchase_orders(recommendations) do
    recommendations
    |> Enum.group_by(& &1.supplier_id)
    |> Enum.reduce_while({:ok, []}, fn {supplier_id, recs}, {:ok, acc} ->
      case PurchaseOrder.create_from_recommendations(supplier_id, recs) do
        {:ok, po}    -> {:cont, {:ok, [po | acc]}}
        {:error, _}  = err -> {:halt, err}
      end
    end)
  end

  # ------------------------------------------------------------------
  # Private helpers
  # ------------------------------------------------------------------

  # VALIDATION: SMELL START - Feature Envy
  # VALIDATION: This is a smell because evaluate_variant/1 is defined in
  # VALIDATION: ReplenishmentPlanner but derives almost all of its data from
  # VALIDATION: ProductVariant. It calls:
  # VALIDATION:   - ProductVariant.get_supplier/1
  # VALIDATION:   - ProductVariant.average_daily_demand/2
  # VALIDATION:   - ProductVariant.lead_time_days/1
  # VALIDATION:   - ProductVariant.safety_stock/2
  # VALIDATION:   - ProductVariant.reorder_quantity/1
  # VALIDATION: and reads variant.id, variant.sku, variant.warehouse_id,
  # VALIDATION: variant.min_order_qty, and variant.unit_cost directly.
  # VALIDATION: ReplenishmentPlanner only provides the comparison with
  # VALIDATION: the current on-hand quantity. This function should live
  # VALIDATION: inside ProductVariant.
  defp evaluate_variant(variant) do
    supplier       = ProductVariant.get_supplier(variant)
    daily_demand   = ProductVariant.average_daily_demand(variant, days: @demand_window_days)
    lead_time      = ProductVariant.lead_time_days(variant)
    safety_stock   = ProductVariant.safety_stock(variant, factor: @safety_stock_factor)
    reorder_qty    = ProductVariant.reorder_quantity(variant)

    reorder_point  = daily_demand * lead_time + safety_stock
    on_hand        = StockLedger.on_hand_quantity(variant.id, variant.warehouse_id)

    if on_hand <= reorder_point do
      suggested_qty = max(reorder_qty, variant.min_order_qty)

      %PurchaseRecommendation{
        variant_id:       variant.id,
        sku:              variant.sku,
        warehouse_id:     variant.warehouse_id,
        supplier_id:      supplier.id,
        supplier_name:    supplier.name,
        supplier_score:   Supplier.reliability_score(supplier),
        on_hand_qty:      on_hand,
        reorder_point:    reorder_point,
        suggested_qty:    suggested_qty,
        estimated_cost:   Decimal.mult(variant.unit_cost, Decimal.new(suggested_qty)),
        priority:         if(on_hand == 0, do: :urgent, else: :normal),
        low_supplier_risk: Supplier.reliability_score(supplier) < @low_supplier_score
      }
    else
      nil
    end
  end
  # VALIDATION: SMELL END

  defp log_summary(recommendations) do
    urgent = Enum.count(recommendations, &(&1.priority == :urgent))
    normal = Enum.count(recommendations, &(&1.priority == :normal))

    require Logger
    Logger.info("[ReplenishmentPlanner] run complete",
      urgent_count: urgent,
      normal_count: normal,
      total: urgent + normal
    )
  end
end
```
