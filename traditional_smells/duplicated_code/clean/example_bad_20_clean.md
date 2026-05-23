```elixir
defmodule Ecommerce.Cart do
  @moduledoc """
  Manages shopping cart operations including item management,
  coupon application, store credit redemption, and checkout preparation.
  """

  alias Ecommerce.Repo
  alias Ecommerce.Cart
  alias Ecommerce.Coupon
  alias Ecommerce.StoreCredit
  alias Ecommerce.LineItem

  @doc """
  Applies a coupon code to a cart.
  Validates the coupon is active and that the cart meets the minimum order value.
  """
  def apply_coupon(%Cart{} = cart, coupon_code) do
    with {:ok, coupon} <- fetch_active_coupon(coupon_code) do
      subtotal_cents =
        cart.line_items
        |> Enum.reduce(0, fn %LineItem{} = li, acc ->
          acc + li.quantity * li.unit_price_cents
        end)

      if subtotal_cents < coupon.minimum_order_cents do
        {:error, {:minimum_not_met, coupon.minimum_order_cents}}
      else
        {:ok, {subtotal_cents, coupon}}
      end
    end
    |> case do
      {:ok, {subtotal_cents, coupon}} ->
        discount =
          case coupon.type do
            :percent -> round(subtotal_cents * coupon.value / 100)
            :fixed -> min(coupon.value, subtotal_cents)
          end

        updated = %{cart | coupon_code: coupon_code, coupon_discount_cents: discount}
        Repo.update(updated)
        {:ok, updated}

      error ->
        error
    end
  end

  @doc """
  Applies store credit to a cart up to the available balance.
  Validates the cart meets the minimum order value for credit redemption.
  """
  def apply_store_credit(%Cart{} = cart, %StoreCredit{} = credit) do
    @minimum_order_for_credit = 500

    subtotal_cents =
      cart.line_items
      |> Enum.reduce(0, fn %LineItem{} = li, acc ->
        acc + li.quantity * li.unit_price_cents
      end)

    if subtotal_cents < @minimum_order_for_credit do
      {:error, :order_too_small_for_credit}
    else
      {:ok, subtotal_cents}
    end
    |> case do
      {:ok, subtotal_cents} ->
        applied_cents = min(credit.balance_cents, subtotal_cents)
        updated_credit = %{credit | balance_cents: credit.balance_cents - applied_cents}
        updated_cart = %{cart | store_credit_cents: applied_cents}
        Repo.update(updated_credit)
        Repo.update(updated_cart)
        {:ok, updated_cart}

      error ->
        error
    end
  end

  @doc """
  Returns the current grand total for the cart in cents,
  after all discounts and credits.
  """
  def grand_total(%Cart{} = cart) do
    subtotal =
      Enum.reduce(cart.line_items, 0, fn li, acc -> acc + li.quantity * li.unit_price_cents end)

    subtotal
    |> Kernel.-(cart.coupon_discount_cents || 0)
    |> Kernel.-(cart.store_credit_cents || 0)
    |> max(0)
  end

  defp fetch_active_coupon(code) do
    case Repo.get_by(Coupon, code: code, status: :active) do
      nil -> {:error, :coupon_not_found}
      coupon ->
        if Date.compare(coupon.expires_at, Date.utc_today()) == :lt do
          {:error, :coupon_expired}
        else
          {:ok, coupon}
        end
    end
  end
end
```
