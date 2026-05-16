# Code Smell: Accessing Non-Existent Map/Struct Fields

- **Smell name:** Accessing non-existent Map/Struct fields
- **Expected smell location:** `Ecommerce.PromotionEngine.apply_promotion/2`, where optional promotion configuration fields are accessed dynamically
- **Affected function(s):** `apply_promotion/2`
- **Short explanation:** The function reads `:max_discount_amount`, `:applies_to_category`, and `:requires_coupon_code` from the promotion map using bracket access. Absent keys return `nil`, so the cap on discounts is silently ignored (`nil` comparison always fails), category scoping is disabled without notice, and coupon requirements are never enforced.

```elixir
defmodule Ecommerce.PromotionEngine do
  @moduledoc """
  Evaluates and applies promotional discounts to shopping carts.
  Supports percentage discounts, flat discounts, minimum order thresholds,
  category restrictions, and coupon code requirements.
  """

  require Logger

  @promotion_types [:percentage, :flat, :free_shipping, :bogo]

  @type cart_item :: %{
          sku: String.t(),
          category: String.t(),
          quantity: pos_integer(),
          unit_price: float()
        }

  @type cart :: %{
          id: String.t(),
          customer_id: String.t(),
          items: [cart_item()],
          subtotal: float(),
          applied_coupon: String.t() | nil
        }

  @type promotion :: %{
          id: String.t(),
          type: atom(),
          value: float(),
          minimum_order: float(),
          active: boolean(),
          optional(:max_discount_amount) => float(),
          optional(:applies_to_category) => String.t(),
          optional(:requires_coupon_code) => String.t(),
          optional(:stackable) => boolean()
        }

  @spec apply_promotion(cart(), promotion()) ::
          {:ok, map()} | {:error, String.t()}
  def apply_promotion(cart, promotion) do
    with :ok <- check_active(promotion),
         :ok <- check_minimum_order(cart, promotion),
         :ok <- check_coupon(cart, promotion),
         {:ok, discount} <- calculate_discount(cart, promotion) do
      result = %{
        cart_id:      cart.id,
        promotion_id: promotion.id,
        original_subtotal: cart.subtotal,
        discount_amount:   discount,
        final_subtotal:    Float.round(cart.subtotal - discount, 2)
      }

      Logger.info("Promotion #{promotion.id} applied to cart #{cart.id}: -#{discount}")
      {:ok, result}
    end
  end

  defp check_active(%{active: true}), do: :ok
  defp check_active(_), do: {:error, "promotion is not active"}

  defp check_minimum_order(cart, promotion) do
    if cart.subtotal >= promotion.minimum_order do
      :ok
    else
      {:error, "cart subtotal #{cart.subtotal} below minimum #{promotion.minimum_order}"}
    end
  end

  defp check_coupon(cart, promotion) do
    # VALIDATION: SMELL START - Accessing non-existent Map/Struct fields
    # VALIDATION: This is a smell because `promotion[:requires_coupon_code]` uses
    # dynamic bracket access on a plain map. If the key is absent, `nil` is returned,
    # which is treated as falsy in the `if` guard. As a result, promotions that should
    # require a coupon code silently skip the check entirely when the field is missing
    # from the map — a promotion intended to be coupon-gated becomes freely applicable.
    requires_coupon_code = promotion[:requires_coupon_code]
    # VALIDATION: SMELL END

    if requires_coupon_code do
      if cart.applied_coupon == requires_coupon_code do
        :ok
      else
        {:error, "coupon code required: #{requires_coupon_code}"}
      end
    else
      :ok
    end
  end

  defp calculate_discount(cart, promotion) do
    category_filter  = promotion[:applies_to_category]
    max_discount     = promotion[:max_discount_amount]

    applicable_items =
      if category_filter do
        Enum.filter(cart.items, &(&1.category == category_filter))
      else
        cart.items
      end

    applicable_subtotal =
      Enum.reduce(applicable_items, 0.0, fn item, acc ->
        acc + item.quantity * item.unit_price
      end)

    raw_discount =
      case promotion.type do
        :percentage    -> Float.round(applicable_subtotal * promotion.value / 100.0, 2)
        :flat          -> min(promotion.value, applicable_subtotal)
        :free_shipping -> 0.0
        _              -> {:error, "unsupported promotion type: #{promotion.type}"}
      end

    capped_discount =
      if max_discount and raw_discount > max_discount do
        max_discount
      else
        raw_discount
      end

    {:ok, capped_discount}
  end

  @spec eligible?(cart(), promotion()) :: boolean()
  def eligible?(cart, promotion) do
    case apply_promotion(cart, promotion) do
      {:ok, _}    -> true
      {:error, _} -> false
    end
  end

  @spec list_applicable(cart(), [promotion()]) :: [promotion()]
  def list_applicable(cart, promotions) do
    Enum.filter(promotions, &eligible?(cart, &1))
  end
end
```
