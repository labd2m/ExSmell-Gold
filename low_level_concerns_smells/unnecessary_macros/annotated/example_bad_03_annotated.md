# Annotated Example 03 — Unnecessary Macros

## Metadata

- **Smell name:** Unnecessary macros
- **Expected smell location:** `defmacro calculate_discount/2` inside `Pricing.DiscountEngine`
- **Affected function(s):** `calculate_discount/2`
- **Short explanation:** The macro computes a runtime discount by multiplying two values — a pure arithmetic operation with no compile-time meaning. This is straightforward function territory and the macro adds unnecessary complexity.

---

```elixir
defmodule Pricing.DiscountEngine do
  @moduledoc """
  Applies promotional and loyalty discounts to order line items.
  Used by the checkout pipeline and the pricing preview API.
  """

  @max_discount_rate 0.50

  # VALIDATION: SMELL START - Unnecessary macros
  # VALIDATION: This is a smell because calculate_discount/2 only multiplies
  # a price by a rate and clamps it — purely runtime arithmetic. No AST
  # transformation is required; a regular def would be cleaner and more idiomatic.
  defmacro calculate_discount(price_cents, rate) do
    quote do
      price = unquote(price_cents)
      discount_rate = min(unquote(rate), @max_discount_rate)
      trunc(price * discount_rate)
    end
  end
  # VALIDATION: SMELL END

  @doc """
  Returns the applicable discount rate for a given coupon code.
  Returns `{:ok, rate}` or `{:error, :invalid_coupon}`.
  """
  @spec coupon_rate(String.t()) :: {:ok, float()} | {:error, :invalid_coupon}
  def coupon_rate(code) do
    coupons = %{
      "SAVE10" => 0.10,
      "SAVE20" => 0.20,
      "WELCOME" => 0.15,
      "FLASH50" => 0.50
    }

    case Map.fetch(coupons, String.upcase(code)) do
      {:ok, rate} -> {:ok, rate}
      :error -> {:error, :invalid_coupon}
    end
  end

  @doc """
  Applies a loyalty discount based on the customer's total historical spend.
  """
  @spec loyalty_rate(non_neg_integer()) :: float()
  def loyalty_rate(lifetime_spend_cents) do
    cond do
      lifetime_spend_cents >= 1_000_000 -> 0.20
      lifetime_spend_cents >= 500_000 -> 0.15
      lifetime_spend_cents >= 100_000 -> 0.10
      lifetime_spend_cents >= 50_000 -> 0.05
      true -> 0.0
    end
  end
end

defmodule Pricing.CheckoutService do
  @moduledoc """
  Orchestrates the checkout process, applying pricing rules,
  discounts, and tax calculations to produce a final order total.
  """

  require Pricing.DiscountEngine

  alias Pricing.DiscountEngine

  @tax_rate 0.08

  @doc """
  Computes the final order breakdown including discounts and tax.
  """
  @spec compute_order(list(map()), String.t() | nil, non_neg_integer()) :: map()
  def compute_order(line_items, coupon_code, lifetime_spend_cents) do
    subtotal = Enum.reduce(line_items, 0, &(&1.price_cents * &1.quantity + &2))

    coupon_discount =
      case coupon_code && DiscountEngine.coupon_rate(coupon_code) do
        {:ok, rate} -> DiscountEngine.calculate_discount(subtotal, rate)
        _ -> 0
      end

    loyalty_rate = DiscountEngine.loyalty_rate(lifetime_spend_cents)
    loyalty_discount = DiscountEngine.calculate_discount(subtotal - coupon_discount, loyalty_rate)

    discounted = subtotal - coupon_discount - loyalty_discount
    tax = trunc(discounted * @tax_rate)
    total = discounted + tax

    %{
      subtotal_cents: subtotal,
      coupon_discount_cents: coupon_discount,
      loyalty_discount_cents: loyalty_discount,
      tax_cents: tax,
      total_cents: total
    }
  end

  @doc """
  Formats a computed order map into a human-readable receipt string.
  """
  @spec format_receipt(map()) :: String.t()
  def format_receipt(order) do
    """
    === Order Receipt ===
    Subtotal:          $#{cents_to_dollars(order.subtotal_cents)}
    Coupon discount:  -$#{cents_to_dollars(order.coupon_discount_cents)}
    Loyalty discount: -$#{cents_to_dollars(order.loyalty_discount_cents)}
    Tax (8%):          $#{cents_to_dollars(order.tax_cents)}
    -----------------------
    Total:             $#{cents_to_dollars(order.total_cents)}
    """
  end

  defp cents_to_dollars(cents) do
    whole = div(cents, 100)
    frac = rem(cents, 100) |> Integer.to_string() |> String.pad_leading(2, "0")
    "#{whole}.#{frac}"
  end
end
```
