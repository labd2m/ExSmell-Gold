```elixir
defmodule MyApp.Retail.PromotionEngine do
  @moduledoc """
  Applies active promotions to a cart, computing discount amounts and
  producing a structured price breakdown. Multiple promotions can apply
  simultaneously; each is evaluated in priority order and a promotion
  can choose to be mutually exclusive with others by returning
  `:exclusive` from its applicability check.

  Promotions are data-driven structs fetched from the database; adding
  a new promotion type requires only a new `Promotion.type` value and
  a matching private dispatch clause.
  """

  alias MyApp.Retail.{Cart, CartItem, Promotion}

  @type discount_line :: %{
          promotion_id: String.t(),
          label: String.t(),
          discount_cents: non_neg_integer()
        }

  @type price_breakdown :: %{
          subtotal_cents: non_neg_integer(),
          discount_lines: [discount_line()],
          total_discount_cents: non_neg_integer(),
          total_cents: non_neg_integer()
        }

  @doc """
  Applies `promotions` to `cart` in priority order and returns a full
  price breakdown. Promotions that are not applicable to the cart are
  silently skipped.
  """
  @spec apply(Cart.t(), [Promotion.t()]) :: price_breakdown()
  def apply(%Cart{} = cart, promotions) when is_list(promotions) do
    subtotal = subtotal_cents(cart)
    sorted = Enum.sort_by(promotions, & &1.priority, :desc)
    {lines, _exclusive} = Enum.reduce(sorted, {[], false}, &evaluate_promotion(&1, &2, cart))

    total_discount = Enum.sum_by(lines, & &1.discount_cents)

    %{
      subtotal_cents: subtotal,
      discount_lines: Enum.reverse(lines),
      total_discount_cents: total_discount,
      total_cents: max(subtotal - total_discount, 0)
    }
  end

  @spec evaluate_promotion(Promotion.t(), {[discount_line()], boolean()}, Cart.t()) ::
          {[discount_line()], boolean()}
  defp evaluate_promotion(_promo, {acc, true}, _cart), do: {acc, true}

  defp evaluate_promotion(promo, {acc, false}, cart) do
    case compute_discount(promo, cart) do
      {:ok, amount, :exclusive} ->
        line = %{promotion_id: promo.id, label: promo.label, discount_cents: amount}
        {[line | acc], true}

      {:ok, amount, :stackable} ->
        line = %{promotion_id: promo.id, label: promo.label, discount_cents: amount}
        {[line | acc], false}

      :not_applicable ->
        {acc, false}
    end
  end

  @spec compute_discount(Promotion.t(), Cart.t()) ::
          {:ok, non_neg_integer(), :exclusive | :stackable} | :not_applicable
  defp compute_discount(%Promotion{type: :percentage_off} = promo, cart) do
    subtotal = subtotal_cents(cart)
    if meets_minimum?(promo, subtotal) do
      discount = div(subtotal * promo.value_bps, 10_000)
      {:ok, discount, promo.exclusive && :exclusive || :stackable}
    else
      :not_applicable
    end
  end

  defp compute_discount(%Promotion{type: :fixed_amount_off} = promo, cart) do
    subtotal = subtotal_cents(cart)
    if meets_minimum?(promo, subtotal) do
      {:ok, min(promo.value_cents, subtotal), :stackable}
    else
      :not_applicable
    end
  end

  defp compute_discount(%Promotion{type: :buy_x_get_y_free} = promo, cart) do
    eligible_items =
      Enum.filter(cart.items, fn item ->
        promo.eligible_skus == [] or item.sku in promo.eligible_skus
      end)

    total_qty = Enum.sum_by(eligible_items, & &1.quantity)
    free_qty = div(total_qty, promo.buy_quantity + promo.free_quantity) * promo.free_quantity

    if free_qty > 0 do
      cheapest_price = eligible_items |> Enum.map(& &1.unit_price_cents) |> Enum.min(fn -> 0 end)
      {:ok, cheapest_price * free_qty, :stackable}
    else
      :not_applicable
    end
  end

  defp compute_discount(_promo, _cart), do: :not_applicable

  @spec subtotal_cents(Cart.t()) :: non_neg_integer()
  defp subtotal_cents(cart) do
    Enum.sum_by(cart.items, fn item -> item.unit_price_cents * item.quantity end)
  end

  @spec meets_minimum?(Promotion.t(), non_neg_integer()) :: boolean()
  defp meets_minimum?(promo, subtotal) do
    is_nil(promo.minimum_order_cents) or subtotal >= promo.minimum_order_cents
  end
end
```
