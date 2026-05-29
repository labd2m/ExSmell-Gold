# Annotated Example – Code Smell

| Field | Value |
|---|---|
| **Smell name** | Long Parameter List |
| **Expected smell location** | `Commerce.Orders.place_order/12` |
| **Affected function(s)** | `place_order/12` |
| **Short explanation** | Twelve parameters collectively express an order, but they span three unrelated concerns: the buyer, the delivery address, and the payment method. Grouping into `%Buyer{}`, `%ShippingAddress{}`, and `%PaymentInfo{}` structs would make each call site self-documenting and much less prone to positional errors. |

```elixir
defmodule Commerce.Orders do
  @moduledoc """
  Manages order placement in the e-commerce checkout pipeline.
  """

  require Logger

  @valid_payment_methods ~w(credit_card pix boleto paypal)
  @max_items 100

  # VALIDATION: SMELL START - Long Parameter List
  # VALIDATION: This is a smell because 12 loosely related parameters must
  # be threaded through the call in exact order. A caller adding a new
  # checkout flow has no compiler-level guard against misplacing
  # `shipping_postal_code` and `billing_postal_code`, which are adjacent
  # positional parameters of the same type. Structs would remove this risk.
  def place_order(
        customer_id,
        customer_email,
        shipping_address,
        shipping_city,
        shipping_postal_code,
        shipping_country,
        items,
        coupon_code,
        payment_method,
        payment_token,
        gift_message,
        subscribe_to_updates
      ) do
    # VALIDATION: SMELL END
    with :ok <- validate_customer(customer_id, customer_email),
         :ok <- validate_address(shipping_address, shipping_city, shipping_postal_code, shipping_country),
         :ok <- validate_items(items),
         :ok <- validate_payment(payment_method, payment_token) do
      subtotal = compute_subtotal(items)
      {:ok, discount} = apply_coupon(subtotal, coupon_code)
      shipping_cost = estimate_shipping(shipping_country, items)
      total = subtotal - discount + shipping_cost

      order = %{
        id: new_order_id(),
        customer_id: customer_id,
        customer_email: customer_email,
        shipping: %{
          address: shipping_address,
          city: shipping_city,
          postal_code: shipping_postal_code,
          country: shipping_country,
          cost: shipping_cost
        },
        items: items,
        coupon_code: coupon_code,
        discount: discount,
        subtotal: subtotal,
        total: total,
        payment: %{method: payment_method, token: mask_token(payment_token)},
        gift_message: gift_message,
        subscribe_to_updates: subscribe_to_updates,
        status: :pending,
        placed_at: DateTime.utc_now()
      }

      case persist_order(order) do
        {:ok, saved} ->
          Logger.info("Order #{saved.id} placed by customer #{customer_id}")
          reserve_stock(saved.items)
          maybe_notify(saved, subscribe_to_updates)
          {:ok, saved}

        {:error, reason} ->
          Logger.error("Order placement failed: #{inspect(reason)}")
          {:error, :placement_failed}
      end
    end
  end

  defp validate_customer(id, email) when is_binary(id) and is_binary(email), do: :ok
  defp validate_customer(_, _), do: {:error, "invalid customer details"}

  defp validate_address(addr, city, postal, country)
       when byte_size(addr) > 0 and byte_size(city) > 0 and
              byte_size(postal) > 0 and byte_size(country) == 2, do: :ok
  defp validate_address(_, _, _, _), do: {:error, "incomplete shipping address"}

  defp validate_items(items) when is_list(items) and length(items) > 0 and length(items) <= @max_items, do: :ok
  defp validate_items(_), do: {:error, "items must be a non-empty list with at most #{@max_items} entries"}

  defp validate_payment(method, token) when method in @valid_payment_methods and byte_size(token) > 0, do: :ok
  defp validate_payment(method, _) when method not in @valid_payment_methods,
    do: {:error, "unsupported payment method: #{method}"}
  defp validate_payment(_, _), do: {:error, "payment_token must not be blank"}

  defp compute_subtotal(items) do
    Enum.reduce(items, Decimal.new(0), fn item, acc ->
      line = Decimal.mult(Decimal.new(item.unit_price), Decimal.new(item.quantity))
      Decimal.add(acc, line)
    end)
  end

  defp apply_coupon(subtotal, nil), do: {:ok, Decimal.new(0)}
  defp apply_coupon(subtotal, _code) do
    {:ok, Decimal.mult(subtotal, Decimal.new("0.10"))}
  end

  defp estimate_shipping("BR", _items), do: Decimal.new("15.00")
  defp estimate_shipping(_, _items), do: Decimal.new("25.00")

  defp persist_order(order), do: {:ok, order}

  defp reserve_stock(items) do
    Logger.debug("Reserving stock for #{length(items)} item(s)")
    :ok
  end

  defp maybe_notify(order, true) do
    Logger.debug("Subscribing #{order.customer_email} to order updates")
    :ok
  end
  defp maybe_notify(_, false), do: :ok

  defp new_order_id do
    "ORD-" <> (:crypto.strong_rand_bytes(8) |> Base.encode16())
  end

  defp mask_token(token) when byte_size(token) > 4 do
    String.duplicate("*", byte_size(token) - 4) <> String.slice(token, -4, 4)
  end
  defp mask_token(token), do: token
end
```
