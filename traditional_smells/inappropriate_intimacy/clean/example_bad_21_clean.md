```elixir
defmodule MyApp.Catalog.PriceCalculator do
  @moduledoc """
  Computes the final display price for a product, applying
  category markup, VAT, and any eligible discount rules.
  """

  alias MyApp.Catalog.{Product, Category, DiscountRule}
  alias MyApp.Finance.VatTable

  def compute(product_id, customer_tier, quantity) do
    with {:ok, product}  <- Product.fetch(product_id),
         {:ok, category} <- Category.fetch(product.category_id) do

      discount_rule = DiscountRule.best_for(product_id, customer_tier, quantity)

      markup_percent  = category.markup_percent
      vat_class       = category.vat_class
      round_strategy  = category.round_strategy

      conditions      = discount_rule && discount_rule.conditions
      discount_type   = discount_rule && discount_rule.discount_type
      discount_value  = discount_rule && discount_rule.discount_value

      base_price    = product.cost_price * (1 + markup_percent / 100)
      vat_rate      = VatTable.rate_for(vat_class)
      price_ex_vat  = base_price
      price_inc_vat = base_price * (1 + vat_rate)

      discount =
        cond do
          is_nil(discount_rule) ->
            0.0

          conditions != nil and not conditions_met?(conditions, quantity, customer_tier) ->
            0.0

          discount_type == :percentage ->
            price_inc_vat * (discount_value / 100)

          discount_type == :fixed ->
            discount_value

          true ->
            0.0
        end

      final = apply_rounding(price_inc_vat - discount, round_strategy)

      {:ok, %{
        product_id:    product_id,
        base_price:    Float.round(base_price, 4),
        markup:        markup_percent,
        vat_rate:      vat_rate,
        vat_class:     vat_class,
        price_ex_vat:  Float.round(price_ex_vat, 2),
        price_inc_vat: Float.round(price_inc_vat, 2),
        discount:      Float.round(discount, 2),
        final_price:   final,
        currency:      product.currency
      }}
    end
  end

  def bulk_compute(product_ids, customer_tier) do
    product_ids
    |> Task.async_stream(&compute(&1, customer_tier, 1), max_concurrency: 20, timeout: 3_000)
    |> Enum.reduce(%{}, fn
      {:ok, {:ok, result}}, acc -> Map.put(acc, result.product_id, result)
      _,                    acc -> acc
    end)
  end


  defp conditions_met?(conditions, quantity, tier) do
    min_qty  = Map.get(conditions, :min_quantity, 1)
    req_tier = Map.get(conditions, :customer_tier)
    quantity >= min_qty and (is_nil(req_tier) or tier == req_tier)
  end

  defp apply_rounding(price, :nearest_cent),   do: Float.round(price, 2)
  defp apply_rounding(price, :nearest_five),    do: Float.round(price / 0.05) * 0.05
  defp apply_rounding(price, :floor_cent),      do: Float.floor(price * 100) / 100
  defp apply_rounding(price, _),                do: Float.round(price, 2)
end
```
