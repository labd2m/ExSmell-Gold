```elixir
defmodule Inventory.Stock.ReorderPlanner do
  @moduledoc """
  Generates automated reorder recommendations based on stock levels,
  consumption velocity, and supplier lead times.

  Evaluates each SKU against configurable reorder policies and produces
  purchase order suggestions for procurement teams.
  """

  alias Inventory.Stock.{StockLevel, ConsumptionHistory, SupplierCatalogue, ReorderPolicy}

  @type reorder_suggestion :: %{
          sku_id: String.t(),
          current_stock: non_neg_integer(),
          days_of_stock_remaining: float(),
          suggested_quantity: pos_integer(),
          supplier_id: String.t(),
          estimated_cost: Decimal.t()
        }

  @doc """
  Generates reorder suggestions for all SKUs matching the given policy.

  Returns a list of suggestions sorted by urgency (lowest days remaining first).
  """
  @spec generate([StockLevel.t()], ReorderPolicy.t(), SupplierCatalogue.t()) ::
          [reorder_suggestion()]
  def generate(stock_levels, %ReorderPolicy{} = policy, %SupplierCatalogue{} = catalogue) do
    stock_levels
    |> Enum.flat_map(&evaluate_sku(&1, policy, catalogue))
    |> Enum.sort_by(& &1.days_of_stock_remaining)
  end

  @doc """
  Computes the days of stock remaining for a given SKU based on consumption velocity.

  Returns `:infinite` when the SKU has no recorded consumption.
  """
  @spec days_remaining(StockLevel.t(), ConsumptionHistory.t()) :: float() | :infinite
  def days_remaining(%StockLevel{quantity: qty}, %ConsumptionHistory{daily_average: avg})
      when avg > 0.0 do
    Float.round(qty / avg, 1)
  end

  def days_remaining(%StockLevel{}, %ConsumptionHistory{}), do: :infinite

  defp evaluate_sku(%StockLevel{sku_id: sku_id} = level, policy, catalogue) do
    with {:ok, history} <- ConsumptionHistory.for_sku(sku_id),
         {:ok, supplier} <- SupplierCatalogue.preferred_supplier(catalogue, sku_id),
         days when is_float(days) <- days_remaining(level, history),
         true <- days <= policy.reorder_threshold_days do
      quantity = compute_reorder_quantity(history, supplier, policy)
      cost = compute_estimated_cost(quantity, supplier)

      suggestion = %{
        sku_id: sku_id,
        current_stock: level.quantity,
        days_of_stock_remaining: days,
        suggested_quantity: quantity,
        supplier_id: supplier.id,
        estimated_cost: cost
      }

      [suggestion]
    else
      _ -> []
    end
  end

  defp compute_reorder_quantity(%ConsumptionHistory{daily_average: avg}, supplier, policy) do
    cover_days = supplier.lead_time_days + policy.safety_stock_days
    raw_quantity = ceil(avg * cover_days)
    round_to_order_multiple(raw_quantity, supplier.minimum_order_quantity)
  end

  defp round_to_order_multiple(quantity, moq) when quantity < moq, do: moq

  defp round_to_order_multiple(quantity, moq) do
    remainder = rem(quantity, moq)
    if remainder == 0, do: quantity, else: quantity + (moq - remainder)
  end

  defp compute_estimated_cost(quantity, supplier) do
    unit_price = resolve_tiered_price(quantity, supplier.price_tiers)
    Decimal.mult(unit_price, Decimal.new(quantity))
  end

  defp resolve_tiered_price(quantity, price_tiers) do
    price_tiers
    |> Enum.sort_by(& &1.min_quantity, :desc)
    |> Enum.find(fn tier -> quantity >= tier.min_quantity end)
    |> case do
      nil -> List.last(Enum.sort_by(price_tiers, & &1.min_quantity)).unit_price
      tier -> tier.unit_price
    end
  end
end
```
