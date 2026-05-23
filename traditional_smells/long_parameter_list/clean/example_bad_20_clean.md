```elixir
defmodule Commerce.Orders do
  @moduledoc """
  Handles end-to-end order placement, including stock reservation,
  coupon application, payment authorisation, and confirmation emails.
  """

  require Logger

  alias Commerce.Repo
  alias Commerce.Schemas.Order
  alias Commerce.Schemas.OrderItem
  alias Commerce.CouponService
  alias Commerce.StockManager
  alias Commerce.PaymentGateway
  alias Commerce.Mailer

  @supported_currencies ~w(USD EUR GBP BRL)

  def place_order(
        customer_id,
        customer_email,
        ship_street,
        ship_city,
        ship_country,
        items,
        coupon_code,
        payment_method_id,
        currency,
        notes
      ) do
    with :ok <- validate_items(items),
         :ok <- validate_currency(currency),
         :ok <- validate_address(ship_street, ship_city, ship_country) do
      discount = resolve_coupon(coupon_code, customer_id)
      subtotal = compute_subtotal(items)
      discount_amount = Decimal.mult(subtotal, Decimal.div(Decimal.new(discount), 100))
      total = Decimal.sub(subtotal, discount_amount)

      Repo.transaction(fn ->
        order_attrs = %{
          customer_id: customer_id,
          customer_email: customer_email,
          ship_street: ship_street,
          ship_city: ship_city,
          ship_country: ship_country,
          subtotal: subtotal,
          discount_percent: discount,
          discount_amount: discount_amount,
          total: total,
          currency: currency,
          coupon_code: coupon_code,
          payment_method_id: payment_method_id,
          notes: notes,
          status: :pending,
          inserted_at: DateTime.utc_now()
        }

        {:ok, order} = Repo.insert(Order.changeset(%Order{}, order_attrs))

        Enum.each(items, fn item ->
          :ok = StockManager.reserve(item.product_id, item.quantity)

          item_attrs = %{
            order_id: order.id,
            product_id: item.product_id,
            quantity: item.quantity,
            unit_price: item.unit_price,
            total: Decimal.mult(item.quantity, item.unit_price)
          }

          Repo.insert!(OrderItem.changeset(%OrderItem{}, item_attrs))
        end)

        case PaymentGateway.authorize(payment_method_id, total, currency) do
          {:ok, auth_ref} ->
            Repo.update!(Order.status_changeset(order, :confirmed, auth_ref))
            Mailer.send_order_confirmation(customer_email, order)
            Logger.info("Order #{order.id} confirmed for customer #{customer_id}")
            {:ok, order}

          {:error, reason} ->
            Logger.error("Payment failed for order #{order.id}: #{reason}")
            Repo.rollback(:payment_failed)
        end
      end)
    end
  end

  defp validate_items([]), do: {:error, :empty_order}

  defp validate_items(items) when is_list(items) do
    valid = Enum.all?(items, fn i -> i[:product_id] && i[:quantity] > 0 && i[:unit_price] end)
    if valid, do: :ok, else: {:error, :invalid_items}
  end

  defp validate_currency(c) when c in @supported_currencies, do: :ok
  defp validate_currency(c), do: {:error, {:unsupported_currency, c}}

  defp validate_address(street, city, country) do
    if Enum.all?([street, city, country], &(is_binary(&1) and String.trim(&1) != "")) do
      :ok
    else
      {:error, :incomplete_address}
    end
  end

  defp resolve_coupon(nil, _), do: 0

  defp resolve_coupon(code, customer_id) do
    case CouponService.apply(code, customer_id) do
      {:ok, discount_pct} -> discount_pct
      _ -> 0
    end
  end

  defp compute_subtotal(items) do
    Enum.reduce(items, Decimal.new(0), fn i, acc ->
      Decimal.add(acc, Decimal.mult(Decimal.new(i.quantity), i.unit_price))
    end)
  end
end
```
