```elixir
defmodule Commerce.CouponService do
  @moduledoc """
  Manages coupon validation and application for the checkout flow.
  """

  alias Commerce.{Coupon, Order, LineItem, Repo, AuditLog}


  @doc """
  Checks whether a coupon code is applicable to the given order without
  mutating any state. Returns `{:ok, discount_cents}` or `{:error, reason}`.
  """
  def validate_coupon(code, %Order{} = order, %{id: user_id}) do
    with {:ok, coupon} <- fetch_active_coupon(code) do
      now = DateTime.utc_now()

      cond do
        not is_nil(coupon.expires_at) and DateTime.compare(now, coupon.expires_at) == :gt ->
          {:error, :coupon_expired}

        not is_nil(coupon.max_uses) and coupon.use_count >= coupon.max_uses ->
          {:error, :coupon_exhausted}

        order.subtotal_cents < coupon.minimum_order_cents ->
          {:error, {:below_minimum, coupon.minimum_order_cents}}

        not Enum.empty?(coupon.allowed_categories) and
            not any_item_in_categories?(order.line_items, coupon.allowed_categories) ->
          {:error, :no_eligible_items}

        true ->
          {:ok, compute_discount(coupon, order.subtotal_cents)}
      end
    end
  end


  @doc """
  Applies a coupon code to the order, records usage, and returns the
  updated order with the discount applied.
  """
  def apply_coupon(code, %Order{} = order, %{id: user_id}) do
    with {:ok, coupon} <- fetch_active_coupon(code) do
      now = DateTime.utc_now()

      cond do
        not is_nil(coupon.expires_at) and DateTime.compare(now, coupon.expires_at) == :gt ->
          {:error, :coupon_expired}

        not is_nil(coupon.max_uses) and coupon.use_count >= coupon.max_uses ->
          {:error, :coupon_exhausted}

        order.subtotal_cents < coupon.minimum_order_cents ->
          {:error, {:below_minimum, coupon.minimum_order_cents}}

        not Enum.empty?(coupon.allowed_categories) and
            not any_item_in_categories?(order.line_items, coupon.allowed_categories) ->
          {:error, :no_eligible_items}

        true ->
          discount = compute_discount(coupon, order.subtotal_cents)

          updated_order = %{order | discount_cents: discount, coupon_code: code}

          Repo.transaction(fn ->
            Repo.update!(order, updated_order)
            Repo.update!(coupon, %{use_count: coupon.use_count + 1})
            AuditLog.log(:coupon_applied, %{
              coupon_id: coupon.id,
              order_id:  order.id,
              user_id:   user_id,
              discount:  discount
            })
          end)

          {:ok, updated_order}
      end
    end
  end


  defp fetch_active_coupon(code) do
    case Repo.get_coupon_by_code(code) do
      nil                               -> {:error, :coupon_not_found}
      %Coupon{active: false}            -> {:error, :coupon_inactive}
      coupon                            -> {:ok, coupon}
    end
  end

  defp compute_discount(%Coupon{type: :percentage, value: pct}, subtotal) do
    round(subtotal * pct / 100)
  end
  defp compute_discount(%Coupon{type: :fixed, value: cents}, _subtotal), do: cents

  defp any_item_in_categories?(line_items, categories) do
    Enum.any?(line_items, fn %LineItem{category: cat} -> cat in categories end)
  end
end
```
