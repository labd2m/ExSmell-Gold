# Annotated Example — Duplicated Code

| Field | Value |
|---|---|
| **Smell name** | Duplicated Code |
| **Expected smell location** | `Commerce.CouponService.apply_coupon/3` and `Commerce.CouponService.validate_coupon/3` |
| **Affected functions** | `apply_coupon/3`, `validate_coupon/3` |
| **Short explanation** | Both functions independently reproduce the coupon applicability checks (expiry, usage cap, minimum order value, allowed categories). If a new restriction is added—such as a customer-tier requirement—it must be inserted in both functions. |

```elixir
defmodule Commerce.CouponService do
  @moduledoc """
  Manages coupon validation and application for the checkout flow.
  """

  alias Commerce.{Coupon, Order, LineItem, Repo, AuditLog}

  # ---------------------------------------------------------------------------
  # Validation endpoint (used by the frontend before checkout)
  # ---------------------------------------------------------------------------

  @doc """
  Checks whether a coupon code is applicable to the given order without
  mutating any state. Returns `{:ok, discount_cents}` or `{:error, reason}`.
  """
  def validate_coupon(code, %Order{} = order, %{id: user_id}) do
    with {:ok, coupon} <- fetch_active_coupon(code) do
      # VALIDATION: SMELL START - Duplicated Code
      # VALIDATION: This is a smell because the applicability checks
      # (expiry, usage cap, minimum order, allowed categories) are
      # reproduced identically in apply_coupon/3. Adding a new constraint
      # requires changes in both functions.
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
      # VALIDATION: SMELL END
    end
  end

  # ---------------------------------------------------------------------------
  # Apply endpoint (called at checkout commit)
  # ---------------------------------------------------------------------------

  @doc """
  Applies a coupon code to the order, records usage, and returns the
  updated order with the discount applied.
  """
  def apply_coupon(code, %Order{} = order, %{id: user_id}) do
    with {:ok, coupon} <- fetch_active_coupon(code) do
      # VALIDATION: SMELL START - Duplicated Code
      # VALIDATION: This is a smell because the exact same applicability
      # check block from validate_coupon/3 is copy-pasted here. Any new
      # business rule (e.g. one-per-customer) must be added in both places.
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
      # VALIDATION: SMELL END
    end
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

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
