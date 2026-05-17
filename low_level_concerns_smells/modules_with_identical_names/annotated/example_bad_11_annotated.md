# Annotated Example 11 — Modules with Identical Names

## Metadata

- **Smell name:** Modules with Identical Names
- **Expected smell location:** Two separate files both define `Orders.Cart`
- **Affected functions:** `Orders.Cart.add_item/2` (file one) and `Orders.Cart.apply_coupon/2` (file two)
- **Explanation:** `Orders.Cart` is defined in `lib/orders/cart.ex` and also in `lib/orders/cart_discounts.ex`. BEAM's module system is flat: each atom (module name) maps to exactly one loaded module. The second file to be compiled replaces the first entirely, dropping one half of the cart API silently.

---

```elixir
# ── file: lib/orders/cart.ex ──────────────────────────────────────────────────

defmodule Orders.Cart do
  @moduledoc """
  Manages shopping cart state including item addition, removal, and quantity
  updates. Persists cart state in the session store for anonymous users and
  in the database for authenticated users.
  """

  alias Orders.{CartStore, Catalog, PricingEngine}

  @max_items_per_cart 100
  @max_quantity_per_item 50

  @type cart_item :: %{
          sku_id: String.t(),
          quantity: pos_integer(),
          unit_price: Decimal.t(),
          name: String.t(),
          image_url: String.t() | nil
        }

  @type t :: %{
          id: String.t(),
          user_id: String.t() | nil,
          items: [cart_item()],
          coupon_code: String.t() | nil,
          subtotal: Decimal.t(),
          discount: Decimal.t(),
          total: Decimal.t(),
          updated_at: DateTime.t()
        }

  # VALIDATION: SMELL START - Modules with Identical Names
  # VALIDATION: This is a smell because `Orders.Cart` is defined again in
  # `lib/orders/cart_discounts.ex`. BEAM replaces the first-compiled module
  # with the second. `add_item/2` and `remove_item/2` will vanish at runtime
  # if the discount file is compiled after this one.

  @spec add_item(String.t(), map()) :: {:ok, t()} | {:error, term()}
  def add_item(cart_id, %{sku_id: sku_id, quantity: qty} = attrs) do
    with {:ok, cart} <- CartStore.get(cart_id),
         {:ok, product} <- Catalog.get_product(sku_id),
         :ok <- validate_product_available(product),
         :ok <- validate_cart_capacity(cart, qty),
         :ok <- validate_quantity(qty) do
      price = PricingEngine.resolve(sku_id, Map.get(attrs, :context, %{}))

      existing_item = Enum.find(cart.items, &(&1.sku_id == sku_id))

      updated_items =
        if existing_item do
          Enum.map(cart.items, fn item ->
            if item.sku_id == sku_id do
              %{item | quantity: min(item.quantity + qty, @max_quantity_per_item)}
            else
              item
            end
          end)
        else
          new_item = %{
            sku_id: sku_id,
            quantity: qty,
            unit_price: price,
            name: product.name,
            image_url: product.thumbnail_url
          }

          [new_item | cart.items]
        end

      updated_cart = recalculate(%{cart | items: updated_items})
      CartStore.put(updated_cart)
      {:ok, updated_cart}
    end
  end

  # VALIDATION: SMELL END

  @spec remove_item(String.t(), String.t()) :: {:ok, t()} | {:error, term()}
  def remove_item(cart_id, sku_id) do
    with {:ok, cart} <- CartStore.get(cart_id) do
      updated_items = Enum.reject(cart.items, &(&1.sku_id == sku_id))
      updated_cart = recalculate(%{cart | items: updated_items})
      CartStore.put(updated_cart)
      {:ok, updated_cart}
    end
  end

  @spec update_quantity(String.t(), String.t(), pos_integer()) :: {:ok, t()} | {:error, term()}
  def update_quantity(cart_id, sku_id, new_qty) when new_qty > 0 do
    with {:ok, cart} <- CartStore.get(cart_id),
         :ok <- validate_quantity(new_qty) do
      updated_items =
        Enum.map(cart.items, fn item ->
          if item.sku_id == sku_id, do: %{item | quantity: new_qty}, else: item
        end)

      updated_cart = recalculate(%{cart | items: updated_items})
      CartStore.put(updated_cart)
      {:ok, updated_cart}
    end
  end

  defp recalculate(cart) do
    subtotal =
      Enum.reduce(cart.items, Decimal.new(0), fn item, acc ->
        Decimal.add(acc, Decimal.mult(item.unit_price, item.quantity))
      end)

    total = Decimal.sub(subtotal, cart.discount || Decimal.new(0))

    %{cart | subtotal: subtotal, total: total, updated_at: DateTime.utc_now()}
  end

  defp validate_product_available(%{available: true}), do: :ok
  defp validate_product_available(_), do: {:error, :product_unavailable}

  defp validate_cart_capacity(%{items: items}, _qty) when length(items) >= @max_items_per_cart do
    {:error, :cart_full}
  end

  defp validate_cart_capacity(_, _), do: :ok

  defp validate_quantity(qty) when qty > 0 and qty <= @max_quantity_per_item, do: :ok
  defp validate_quantity(_), do: {:error, :invalid_quantity}
end


# ── file: lib/orders/cart_discounts.ex ───────────────────────────────────────

defmodule Orders.Cart do
  @moduledoc """
  Handles coupon code application, automatic promotions, and discount
  calculation for shopping carts.
  """

  alias Orders.{CartStore, CouponEngine, PromotionEngine}

  @spec apply_coupon(String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def apply_coupon(cart_id, coupon_code) do
    with {:ok, cart} <- CartStore.get(cart_id),
         {:ok, coupon} <- CouponEngine.validate(coupon_code),
         :ok <- CouponEngine.check_eligibility(coupon, cart) do
      discount = CouponEngine.compute_discount(coupon, cart.subtotal)

      updated =
        cart
        |> Map.put(:coupon_code, coupon_code)
        |> Map.put(:coupon_id, coupon.id)
        |> Map.put(:discount, discount)
        |> Map.put(:total, Decimal.sub(cart.subtotal, discount))
        |> Map.put(:updated_at, DateTime.utc_now())

      CartStore.put(updated)
      {:ok, updated}
    end
  end

  @spec remove_coupon(String.t()) :: {:ok, map()} | {:error, :not_found}
  def remove_coupon(cart_id) do
    with {:ok, cart} <- CartStore.get(cart_id) do
      updated =
        cart
        |> Map.put(:coupon_code, nil)
        |> Map.put(:coupon_id, nil)
        |> Map.put(:discount, Decimal.new(0))
        |> Map.put(:total, cart.subtotal)
        |> Map.put(:updated_at, DateTime.utc_now())

      CartStore.put(updated)
      {:ok, updated}
    end
  end

  @spec apply_automatic_promotions(String.t()) :: {:ok, map()}
  def apply_automatic_promotions(cart_id) do
    with {:ok, cart} <- CartStore.get(cart_id) do
      promotions = PromotionEngine.applicable(cart)

      {discount, applied} =
        Enum.reduce(promotions, {Decimal.new(0), []}, fn promo, {acc_discount, acc_applied} ->
          d = PromotionEngine.compute(promo, cart)
          {Decimal.add(acc_discount, d), [promo.id | acc_applied]}
        end)

      updated =
        cart
        |> Map.put(:applied_promotions, applied)
        |> Map.put(:promotion_discount, discount)
        |> Map.put(:updated_at, DateTime.utc_now())

      CartStore.put(updated)
      {:ok, updated}
    end
  end
end
```
