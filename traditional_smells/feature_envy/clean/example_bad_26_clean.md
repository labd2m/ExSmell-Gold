```elixir
defmodule Store.CartItem do
  @moduledoc "Represents a single item in a customer's shopping cart."

  defstruct [
    :id,
    :cart_id,
    :product_id,
    :variant_id,
    :quantity,
    :unit_price,
    :item_type,
    :bundle_items,
    :promo_eligible,
    :added_at
  ]

  def get!(id) do
    %__MODULE__{
      id: id,
      cart_id: "CART-991",
      product_id: "PROD-33",
      variant_id: "VAR-A",
      quantity: 2,
      unit_price: Decimal.new("39.99"),
      item_type: :bundle,
      bundle_items: ["SKU-AA", "SKU-BB", "SKU-CC"],
      promo_eligible: true,
      added_at: DateTime.utc_now()
    }
  end

  def line_subtotal(%__MODULE__{unit_price: price, quantity: qty}) do
    Decimal.mult(price, Decimal.new(qty))
  end

  def is_bundle?(%__MODULE__{item_type: :bundle}), do: true
  def is_bundle?(_), do: false

  def bundle_size(%__MODULE__{bundle_items: items}) when is_list(items), do: length(items)
  def bundle_size(_), do: 0

  def eligible_for_promo?(%__MODULE__{promo_eligible: true}), do: true
  def eligible_for_promo?(_), do: false

  def display_label(%__MODULE__{product_id: pid, variant_id: vid}) do
    "#{pid} / #{vid}"
  end
end

defmodule Store.Promotion do
  @moduledoc "Available promotional rule definitions."

  def bundle_discount_rate(bundle_size) when bundle_size >= 5, do: Decimal.new("0.20")
  def bundle_discount_rate(bundle_size) when bundle_size >= 3, do: Decimal.new("0.10")
  def bundle_discount_rate(_), do: Decimal.new("0.00")
end

defmodule Store.PromotionApplier do
  @moduledoc """
  Applies promotion rules to cart items and returns adjusted line totals
  for checkout summary display.
  """

  alias Store.{CartItem, Promotion}
  require Logger

  @doc """
  Computes the promotion-adjusted total for a list of cart item IDs.
  Returns a map with the original total, discount, and final total.
  """
  def compute_adjusted_cart(item_ids) do
    results = Enum.map(item_ids, fn id ->
      item     = CartItem.get!(id)
      original = CartItem.line_subtotal(item)
      discount = apply_bundle_discount(id)

      %{
        item_id:  id,
        label:    CartItem.display_label(item),
        original: original,
        discount: discount,
        final:    Decimal.sub(original, discount)
      }
    end)

    total_original = results |> Enum.map(& &1.original) |> Enum.reduce(Decimal.new("0"), &Decimal.add/2)
    total_discount = results |> Enum.map(& &1.discount)  |> Enum.reduce(Decimal.new("0"), &Decimal.add/2)

    %{
      items:          results,
      total_original: Decimal.round(total_original, 2),
      total_discount: Decimal.round(total_discount, 2),
      total_final:    Decimal.round(Decimal.sub(total_original, total_discount), 2)
    }
  end

  defp apply_bundle_discount(item_id) do
    item      = CartItem.get!(item_id)
    subtotal  = CartItem.line_subtotal(item)
    bundle    = CartItem.is_bundle?(item)
    size      = CartItem.bundle_size(item)
    eligible  = CartItem.eligible_for_promo?(item)

    if bundle and eligible do
      rate = Promotion.bundle_discount_rate(size)
      Decimal.round(Decimal.mult(subtotal, rate), 2)
    else
      Decimal.new("0.00")
    end
  end
end
```
