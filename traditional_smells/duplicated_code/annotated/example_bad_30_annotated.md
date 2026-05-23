# Annotated Example — Duplicated Code

## Metadata

- **Smell name:** Duplicated Code
- **Expected smell location:** `OrderProcessor.apply_coupon/2` and `OrderProcessor.apply_loyalty_credit/2`
- **Affected functions:** `apply_coupon/2`, `apply_loyalty_credit/2`
- **Short explanation:** Both functions independently validate that the order is in a mutable state, compute the new order total after deducting the discount, enforce a zero floor, and persist the updated order. This adjustment pipeline is duplicated instead of shared.

---

```elixir
defmodule OrderProcessor do
  @moduledoc """
  Handles order creation, discount application, and fulfilment state transitions.
  """

  alias Commerce.{Order, Coupon, LoyaltyAccount, OrderLine, EventBus}

  @mutable_statuses [:draft, :pending_payment]
  @minimum_order_total Decimal.new("0.00")

  def create_order(customer_id, cart_items) do
    lines =
      Enum.map(cart_items, fn item ->
        %OrderLine{
          sku: item.sku,
          name: item.name,
          quantity: item.quantity,
          unit_price: Decimal.new(to_string(item.unit_price)),
          line_total: Decimal.mult(Decimal.new(to_string(item.unit_price)), item.quantity)
        }
      end)

    subtotal = Enum.reduce(lines, Decimal.new("0"), fn l, acc -> Decimal.add(acc, l.line_total) end)

    order = %Order{
      id: Ecto.UUID.generate(),
      customer_id: customer_id,
      lines: lines,
      subtotal: subtotal,
      discount_total: Decimal.new("0.00"),
      total: subtotal,
      status: :draft,
      created_at: DateTime.utc_now()
    }

    Commerce.Repo.insert(order)
  end

  def apply_coupon(%Order{} = order, coupon_code) do
    with {:ok, coupon} <- Coupon.fetch_active(coupon_code),
         :ok <- Coupon.validate_applicability(coupon, order),
         # VALIDATION: SMELL START - Duplicated Code
         # VALIDATION: This is a smell because the mutable-status check,
         # discount subtraction, zero-floor enforcement, and order persistence
         # are duplicated verbatim in `apply_loyalty_credit/2`.
         true <- order.status in @mutable_statuses do

      discount_amount = Coupon.compute_discount(coupon, order.total)
      new_total = Decimal.sub(order.total, discount_amount)

      new_total =
        if Decimal.lt?(new_total, @minimum_order_total),
          do: @minimum_order_total,
          else: new_total

      updated_discount = Decimal.add(order.discount_total, discount_amount)

      updated =
        Order.update(order, %{
          total: new_total,
          discount_total: updated_discount,
          coupon_code: coupon_code,
          updated_at: DateTime.utc_now()
        })

      EventBus.publish(:coupon_applied, %{order_id: order.id, coupon: coupon_code})
      {:ok, updated}
      # VALIDATION: SMELL END
    else
      false -> {:error, :order_not_editable}
      error -> error
    end
  end

  def apply_loyalty_credit(%Order{} = order, customer_id) do
    with {:ok, account} <- LoyaltyAccount.fetch(customer_id),
         {:ok, credit} <- LoyaltyAccount.redeemable_credit(account, order.total),
         # VALIDATION: SMELL START - Duplicated Code
         # VALIDATION: This is a smell because the four-step discount application
         # block here duplicates the one in `apply_coupon/2`. Any change to the
         # floor logic or order-update structure must be made in both functions.
         true <- order.status in @mutable_statuses do

      discount_amount = credit
      new_total = Decimal.sub(order.total, discount_amount)

      new_total =
        if Decimal.lt?(new_total, @minimum_order_total),
          do: @minimum_order_total,
          else: new_total

      updated_discount = Decimal.add(order.discount_total, discount_amount)

      updated =
        Order.update(order, %{
          total: new_total,
          discount_total: updated_discount,
          loyalty_credit_applied: discount_amount,
          updated_at: DateTime.utc_now()
        })

      LoyaltyAccount.deduct(account, discount_amount)
      EventBus.publish(:loyalty_credit_applied, %{order_id: order.id, credit: credit})
      {:ok, updated}
      # VALIDATION: SMELL END
    else
      false -> {:error, :order_not_editable}
      error -> error
    end
  end

  def confirm_order(%Order{status: :pending_payment} = order) do
    updated = Order.update(order, %{status: :confirmed, confirmed_at: DateTime.utc_now()})
    EventBus.publish(:order_confirmed, %{order_id: order.id})
    {:ok, updated}
  end

  def confirm_order(_order), do: {:error, :invalid_status_transition}
end
```
