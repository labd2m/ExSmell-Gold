# Annotated Example 10 — Long Parameter List

## Metadata

- **Smell name:** Long Parameter List
- **Expected smell location:** `Ecommerce.Orders.place_order/13`
- **Affected function(s):** `place_order/13`
- **Short explanation:** The function accepts 13 positional parameters spanning customer identification, shipping address, payment method, cart items, and fulfilment options. These clearly belong in a structured `Order` type or a well-keyed map.

---

```elixir
defmodule Ecommerce.Orders do
  @moduledoc """
  Handles order placement, validation, inventory reservation, and payment capture in the
  e-commerce platform.
  """

  require Logger

  alias Ecommerce.{
    Cart,
    Inventory,
    Payments,
    Shipment,
    Order,
    Repo
  }

  @shipping_methods [:standard, :express, :overnight, :pickup]

  # VALIDATION: SMELL START - Long Parameter List
  # VALIDATION: This is a smell because 13 positional parameters are required,
  # VALIDATION: merging customer info, delivery address, payment details, item list,
  # VALIDATION: and fulfilment options. This interface is unsafe and hard to evolve.
  def place_order(
        customer_id,
        customer_email,
        shipping_name,
        shipping_street,
        shipping_city,
        shipping_zip,
        shipping_country,
        payment_method_token,
        cart_items,
        shipping_method,
        coupon_code,
        gift_message,
        send_confirmation
      ) do
    # VALIDATION: SMELL END

    with :ok <- validate_customer(customer_id),
         :ok <- validate_cart(cart_items),
         :ok <- validate_shipping_method(shipping_method),
         {:ok, pricing} <- Cart.calculate(cart_items, coupon_code),
         :ok <- Inventory.reserve_all(cart_items) do

      order = %Order{
        id: generate_order_id(),
        customer_id: customer_id,
        customer_email: customer_email,
        shipping_address: %{
          name: shipping_name,
          street: shipping_street,
          city: shipping_city,
          zip: shipping_zip,
          country: shipping_country
        },
        items: cart_items,
        subtotal: pricing.subtotal,
        discount: pricing.discount,
        shipping_cost: pricing.shipping_cost,
        tax: pricing.tax,
        total: pricing.total,
        coupon_code: coupon_code,
        gift_message: gift_message,
        shipping_method: shipping_method,
        status: :pending_payment,
        placed_at: DateTime.utc_now()
      }

      case Payments.charge(customer_id, payment_method_token, pricing.total, "Order #{order.id}") do
        {:ok, charge} ->
          confirmed_order = struct(order, status: :confirmed, payment_id: charge.id)

          case Repo.insert(confirmed_order) do
            {:ok, saved} ->
              Shipment.create_for_order(saved, shipping_method)

              if send_confirmation do
                Ecommerce.Mailer.send_order_confirmation(customer_email, saved)
              end

              Logger.info("Order #{saved.id} placed by customer #{customer_id}")
              {:ok, saved}

            {:error, reason} ->
              Payments.refund(charge.id)
              Inventory.release_all(cart_items)
              {:error, reason}
          end

        {:error, reason} ->
          Inventory.release_all(cart_items)
          Logger.warning("Payment failed for order attempt by #{customer_id}: #{inspect(reason)}")
          {:error, {:payment_failed, reason}}
      end
    end
  end

  def get_order(order_id) do
    case Repo.get(Order, order_id) do
      nil -> {:error, :not_found}
      order -> {:ok, order}
    end
  end

  defp validate_customer(id) when is_binary(id) and byte_size(id) > 0, do: :ok
  defp validate_customer(_), do: {:error, :invalid_customer}

  defp validate_cart([]), do: {:error, :empty_cart}
  defp validate_cart(items) when is_list(items), do: :ok
  defp validate_cart(_), do: {:error, :invalid_cart}

  defp validate_shipping_method(m) when m in @shipping_methods, do: :ok
  defp validate_shipping_method(m), do: {:error, {:invalid_shipping_method, m}}

  defp generate_order_id do
    "ORD-" <> (:crypto.strong_rand_bytes(6) |> Base.encode16())
  end
end
```
