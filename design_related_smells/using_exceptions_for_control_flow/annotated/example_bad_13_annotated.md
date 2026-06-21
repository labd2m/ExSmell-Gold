# Code Smell Example — Annotated

## Metadata

- **Smell name:** Using exceptions for control-flow
- **Expected smell location:** `Promotions.CouponRedeemer.redeem/3`
- **Affected function(s):** `Promotions.CouponRedeemer.redeem/3` (library side); `Promotions.CheckoutApplicator.apply_coupon/3` (client side)
- **Explanation:** `redeem/3` raises `RuntimeError` for routine coupon-redemption outcomes: unknown coupon code, already-used coupon, expired coupon, and order total below the minimum threshold. Coupon rejections are a normal part of the checkout flow. Callers cannot inspect structured failure reasons without a `try/rescue`, forcing exception-based control-flow for what is everyday business logic.

```elixir
defmodule Promotions.Coupon do
  @moduledoc "Represents a discount coupon with eligibility rules."

  @enforce_keys [:code, :discount_type, :discount_value, :expires_at, :status]
  defstruct [
    :code,
    :discount_type,
    :discount_value,
    :expires_at,
    :status,
    :min_order_value,
    :max_uses,
    :use_count,
    :applicable_skus
  ]

  def expired?(%__MODULE__{expires_at: exp}) do
    DateTime.compare(exp, DateTime.utc_now()) == :lt
  end

  def exhausted?(%__MODULE__{max_uses: nil}), do: false

  def exhausted?(%__MODULE__{max_uses: max, use_count: count}), do: count >= max
end

defmodule Promotions.CouponStore do
  @moduledoc "In-memory coupon registry."

  alias Promotions.Coupon

  @coupons %{
    "SUMMER10" => %Coupon{
      code: "SUMMER10",
      discount_type: :percentage,
      discount_value: 10,
      expires_at: DateTime.add(DateTime.utc_now(), 3600 * 24 * 30, :second),
      status: :active,
      min_order_value: 50.0,
      max_uses: 1000,
      use_count: 0
    },
    "FREESHIP" => %Coupon{
      code: "FREESHIP",
      discount_type: :flat,
      discount_value: 5.99,
      expires_at: DateTime.add(DateTime.utc_now(), -1, :second),
      status: :active,
      min_order_value: 0,
      max_uses: nil,
      use_count: 0
    }
  }

  def find(code), do: Map.fetch(@coupons, code)
  def record_use(code), do: {:ok, Map.get(@coupons, code)}
end

defmodule Promotions.DiscountCalculator do
  @moduledoc "Calculates the discount amount to apply to a given order total."

  alias Promotions.Coupon

  def calculate(%Coupon{discount_type: :percentage, discount_value: pct}, order_total) do
    Float.round(order_total * pct / 100, 2)
  end

  def calculate(%Coupon{discount_type: :flat, discount_value: flat}, _order_total) do
    flat
  end
end

defmodule Promotions.CouponRedeemer do
  @moduledoc """
  Validates a coupon code and computes the discount for an order.
  Enforces expiry, usage limits, and minimum order value requirements.
  """

  alias Promotions.{Coupon, CouponStore, DiscountCalculator}
  require Logger

  # VALIDATION: SMELL START - Using exceptions for control-flow
  # VALIDATION: This is a smell because `redeem/3` raises RuntimeError for four
  # VALIDATION: routine coupon rejection scenarios: unknown code, expired coupon,
  # VALIDATION: exhausted usage cap, and order below minimum value. Callers at
  # VALIDATION: checkout cannot decide how to present each failure to the user
  # VALIDATION: without catching the exception first, making try/rescue the only
  # VALIDATION: way to distinguish the rejection reason.
  def redeem(coupon_code, order_total, customer_id)
      when is_binary(coupon_code) and is_number(order_total) do
    case CouponStore.find(coupon_code) do
      :error ->
        raise RuntimeError,
          message: "Coupon '#{coupon_code}' does not exist"

      {:ok, coupon} ->
        if Coupon.expired?(coupon) do
          raise RuntimeError,
            message: "Coupon '#{coupon_code}' expired on #{coupon.expires_at}"
        end

        if Coupon.exhausted?(coupon) do
          raise RuntimeError,
            message:
              "Coupon '#{coupon_code}' has reached its maximum usage limit of #{coupon.max_uses}"
        end

        min_val = coupon.min_order_value || 0

        if order_total < min_val do
          raise RuntimeError,
            message:
              "Coupon '#{coupon_code}' requires a minimum order of #{min_val}. " <>
                "Current order total: #{Float.round(order_total, 2)}"
        end

        discount = DiscountCalculator.calculate(coupon, order_total)
        {:ok, _} = CouponStore.record_use(coupon_code)

        Logger.info(
          "Coupon #{coupon_code} redeemed by customer=#{customer_id} " <>
            "discount=#{discount} on order_total=#{order_total}"
        )

        %{
          coupon_code: coupon_code,
          discount_amount: discount,
          discount_type: coupon.discount_type,
          new_total: Float.round(order_total - discount, 2)
        }
    end
  end
  # VALIDATION: SMELL END
end

defmodule Promotions.CheckoutApplicator do
  @moduledoc """
  Applies a coupon to a checkout session. Wraps the redeemer and
  returns a structured result for the checkout controller.
  """

  alias Promotions.CouponRedeemer
  require Logger

  def apply_coupon(coupon_code, order_total, customer_id) do
    # Client forced to use try/rescue because CouponRedeemer.redeem/3 raises
    # on all rejection conditions rather than returning {:error, reason}.
    try do
      result = CouponRedeemer.redeem(coupon_code, order_total, customer_id)

      {:ok,
       %{
         applied: true,
         coupon_code: coupon_code,
         discount: result.discount_amount,
         new_total: result.new_total
       }}
    rescue
      e in RuntimeError ->
        Logger.info("Coupon '#{coupon_code}' rejected for customer=#{customer_id}: #{e.message}")

        {:error,
         %{
           applied: false,
           coupon_code: coupon_code,
           reason: e.message
         }}
    end
  end
end
```
