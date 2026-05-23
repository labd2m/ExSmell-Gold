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
