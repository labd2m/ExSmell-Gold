```elixir
defmodule Inventory.PricingEngine do
  @moduledoc """
  Computes recommended retail prices for inventory SKUs.

  Pricing considers the unit cost, the category margin target, current
  competitor pricing signals, and any active promotional overrides.
  """

  alias Inventory.{SKU, CompetitorPriceIndex, PromotionRegistry}

  require Logger

  @price_floor_multiplier 1.05
  @competitor_weight 0.30
  @cost_weight 0.70

  @spec recommend_price(String.t()) :: {:ok, map()} | {:error, atom()}
  def recommend_price(sku_id) do
    with {:ok, sku} <- SKU.fetch(sku_id),
         {:ok, margin_target} <- determine_margin_target(sku),
         {:ok, competitor_price} <- fetch_competitor_price(sku_id),
         {:ok, promo_override} <- PromotionRegistry.active_override(sku_id) do
      cost_based_price = sku.unit_cost / (1 - margin_target)
      blended_price = blend(cost_based_price, competitor_price)
      floor_price = sku.unit_cost * @price_floor_multiplier

      recommended =
        cond do
          promo_override != nil -> promo_override.price
          blended_price < floor_price -> floor_price
          true -> blended_price
        end

      result = %{
        sku_id: sku_id,
        recommended_price: Float.round(recommended, 2),
        cost_based_price: Float.round(cost_based_price, 2),
        floor_price: Float.round(floor_price, 2),
        margin_target: margin_target,
        promo_active: promo_override != nil
      }

      Logger.debug("Price recommended sku=#{sku_id} price=#{result.recommended_price}")
      {:ok, result}
    end
  end

  @spec bulk_recommend([String.t()]) :: [{String.t(), {:ok, map()} | {:error, atom()}}]
  def bulk_recommend(sku_ids) do
    Enum.map(sku_ids, fn sku_id -> {sku_id, recommend_price(sku_id)} end)
  end

  defp determine_margin_target(%{product_type: product_type}) do
    margin =
      case product_type do
        :hardware -> 0.40
        :consumable -> 0.40
        :accessory -> 0.40
      end

    {:ok, margin}
  end

  defp fetch_competitor_price(sku_id) do
    case CompetitorPriceIndex.latest(sku_id) do
      {:ok, price} -> {:ok, price}
      {:error, :not_found} -> {:ok, nil}
      {:error, reason} -> {:error, reason}
    end
  end

  defp blend(_cost_price, nil), do: nil

  defp blend(cost_price, competitor_price) do
    @cost_weight * cost_price + @competitor_weight * competitor_price
  end
end
```
