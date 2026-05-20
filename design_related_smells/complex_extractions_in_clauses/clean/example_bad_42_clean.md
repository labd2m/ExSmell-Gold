```elixir
defmodule Billing.DiscountEngine do
  @moduledoc """
  Applies discount rules to pending orders based on customer tier,
  loyalty duration, and active promotional codes.
  """

  alias Billing.{Order, Customer, Promotion, AuditLog, Mailer}

  @vip_order_threshold 5_000.0
  @loyalty_years_threshold 3
  @loyalty_discount_rate 0.05
  @loyalty_plus_promo_rate 0.10

  def apply_discount(%Order{
        status: status,
        total: total,
        customer_id: customer_id,
        promo_code: promo_code,
        items: items,
        placed_at: placed_at,
        order_ref: order_ref
      })
      when status == :pending and total >= @vip_order_threshold do
    customer = Customer.get!(customer_id)
    base_discount = calculate_vip_discount(total, customer.tier)
    promotion = maybe_fetch_promotion(promo_code)
    promo_discount = if promotion, do: promotion.value, else: 0.0
    final_discount = Float.round(base_discount + promo_discount, 2)
    discounted_total = Float.round(total - final_discount, 2)

    AuditLog.write(:vip_discount_applied, %{
      order_ref: order_ref,
      customer_id: customer_id,
      original_total: total,
      discount_applied: final_discount,
      items_count: length(items),
      placed_at: placed_at
    })

    Mailer.send_order_confirmation(customer.email, order_ref, discounted_total)
    {:ok, %{order_ref: order_ref, discounted_total: discounted_total, discount: final_discount}}
  end

  def apply_discount(%Order{
        status: status,
        total: total,
        customer_id: customer_id,
        promo_code: promo_code,
        items: items,
        placed_at: placed_at,
        order_ref: order_ref
      })
      when status == :pending and total < @vip_order_threshold do
    customer = Customer.get!(customer_id)
    loyalty_years = Date.diff(Date.utc_today(), customer.member_since) |> div(365)
    promotion = maybe_fetch_promotion(promo_code)

    discount =
      cond do
        loyalty_years >= @loyalty_years_threshold and promotion != nil ->
          Float.round(total * @loyalty_plus_promo_rate + promotion.value, 2)

        loyalty_years >= @loyalty_years_threshold ->
          Float.round(total * @loyalty_discount_rate, 2)

        promotion != nil ->
          Float.round(promotion.value, 2)

        true ->
          0.0
      end

    discounted_total = Float.round(total - discount, 2)

    AuditLog.write(:standard_discount_applied, %{
      order_ref: order_ref,
      customer_id: customer_id,
      loyalty_years: loyalty_years,
      original_total: total,
      discount_applied: discount,
      items_count: length(items),
      placed_at: placed_at
    })

    {:ok, %{order_ref: order_ref, discounted_total: discounted_total, discount: discount}}
  end

  def apply_discount(%Order{
        status: status,
        total: total,
        order_ref: order_ref,
        customer_id: customer_id
      })
      when status in [:completed, :cancelled, :refunded] do
    AuditLog.write(:discount_rejected_finalized, %{
      order_ref: order_ref,
      customer_id: customer_id,
      status: status,
      total: total
    })

    {:error, {:order_not_eligible, order_ref, status}}
  end


  defp calculate_vip_discount(total, :platinum), do: total * 0.20
  defp calculate_vip_discount(total, :gold), do: total * 0.15
  defp calculate_vip_discount(total, :silver), do: total * 0.10
  defp calculate_vip_discount(total, _), do: total * 0.08

  defp maybe_fetch_promotion(nil), do: nil
  defp maybe_fetch_promotion(code), do: Promotion.find_active(code)
end
```
