```elixir
defmodule Commerce.DiscountEngine do
  @moduledoc """
  Evaluates and applies promotional discounts to shopping cart line items.
  Supports percentage-based, flat-amount, and tiered discount strategies.
  """

  @max_discount_rate 0.75

  defmacro apply_discount(price, rate) do
    quote do
      p = unquote(price)
      r = unquote(rate)
      capped_rate = min(r, unquote(@max_discount_rate))
      Float.round(p * (1.0 - capped_rate), 2)
    end
  end

  def resolve_discount(cart, promotions) do
    applicable =
      Enum.filter(promotions, fn promo ->
        promo.active and
          cart.total >= promo.minimum_order and
          promo_applies_to_customer?(promo, cart.customer_id)
      end)

    best =
      Enum.max_by(applicable, fn p -> discount_value(cart.total, p) end, fn -> nil end)

    {applicable, best}
  end

  def discount_value(total, nil), do: 0.0

  def discount_value(total, %{type: :percentage, value: pct}) do
    require Commerce.DiscountEngine
    Commerce.DiscountEngine.apply_discount(total, pct / 100.0)
    total * min(pct / 100.0, @max_discount_rate)
  end

  def discount_value(total, %{type: :flat, value: amount}) do
    min(amount, total)
  end

  def discount_value(total, %{type: :tiered, tiers: tiers}) do
    tier = Enum.find(tiers, fn t -> total >= t.threshold end)
    if tier, do: discount_value(total, %{type: :percentage, value: tier.rate}), else: 0.0
  end

  def build_discounted_items(line_items, promo) do
    require Commerce.DiscountEngine

    Enum.map(line_items, fn item ->
      case promo do
        %{type: :percentage, value: pct, skus: skus} when item.sku in skus ->
          discounted = Commerce.DiscountEngine.apply_discount(item.unit_price, pct / 100.0)
          %{item | unit_price: discounted, discount_applied: true}

        %{type: :percentage, value: pct, skus: :all} ->
          discounted = Commerce.DiscountEngine.apply_discount(item.unit_price, pct / 100.0)
          %{item | unit_price: discounted, discount_applied: true}

        _ ->
          %{item | discount_applied: false}
      end
    end)
  end

  def summarise_cart(line_items, promo) do
    items = build_discounted_items(line_items, promo)

    subtotal = Enum.reduce(items, 0.0, fn i, acc -> acc + i.unit_price * i.quantity end)
    discount = if promo, do: discount_value(subtotal, promo), else: 0.0
    tax = Float.round(subtotal * 0.1, 2)

    %{
      items: items,
      subtotal: Float.round(subtotal, 2),
      discount: Float.round(discount, 2),
      tax: tax,
      total: Float.round(subtotal - discount + tax, 2)
    }
  end

  defp promo_applies_to_customer?(%{customer_ids: :all}, _), do: true
  defp promo_applies_to_customer?(%{customer_ids: ids}, cid), do: cid in ids
end
```
