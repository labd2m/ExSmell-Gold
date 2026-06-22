```elixir
defmodule Commerce.Promotions.CouponRedemptionService do
  @moduledoc """
  Handles coupon validation and redemption for commerce orders.

  Validates coupon eligibility against order contents, customer history,
  and coupon usage limits before applying discounts atomically.
  """

  alias Commerce.Promotions.{Coupon, CouponUsage, DiscountApplication}
  alias Commerce.Orders.Order
  alias Commerce.Repo
  import Ecto.Query, warn: false

  @type redemption_result ::
          {:ok, DiscountApplication.t()}
          | {:error, :coupon_not_found}
          | {:error, :coupon_expired}
          | {:error, :usage_limit_reached}
          | {:error, :minimum_order_not_met}
          | {:error, :customer_already_used}

  @doc """
  Validates and redeems a coupon code for the given order and customer.

  Returns `{:ok, discount_application}` with the computed discount on success.
  """
  @spec redeem(String.t(), Order.t(), String.t()) :: redemption_result()
  def redeem(coupon_code, %Order{} = order, customer_id)
      when is_binary(coupon_code) and is_binary(customer_id) do
    Repo.transaction(fn ->
      with {:ok, coupon} <- fetch_valid_coupon(coupon_code),
           :ok <- check_usage_limit(coupon),
           :ok <- check_customer_usage(coupon, customer_id),
           :ok <- check_minimum_order(coupon, order),
           {:ok, application} <- apply_discount(coupon, order, customer_id) do
        application
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  @doc """
  Returns the redemption history for a specific coupon code.
  """
  @spec redemption_history(String.t()) :: [CouponUsage.t()]
  def redemption_history(coupon_code) when is_binary(coupon_code) do
    CouponUsage
    |> join(:inner, [u], c in Coupon, on: u.coupon_id == c.id)
    |> where([_u, c], c.code == ^coupon_code)
    |> order_by([u, _c], desc: u.redeemed_at)
    |> preload(:customer)
    |> Repo.all()
  end

  defp fetch_valid_coupon(code) do
    now = DateTime.utc_now()

    result =
      Coupon
      |> where([c], c.code == ^code and c.active == true)
      |> where([c], is_nil(c.expires_at) or c.expires_at > ^now)
      |> Repo.one()

    case result do
      nil -> {:error, :coupon_not_found}
      coupon -> check_expiry(coupon)
    end
  end

  defp check_expiry(%Coupon{expires_at: nil} = coupon), do: {:ok, coupon}

  defp check_expiry(%Coupon{expires_at: expires_at} = coupon) do
    if DateTime.compare(DateTime.utc_now(), expires_at) == :lt do
      {:ok, coupon}
    else
      {:error, :coupon_expired}
    end
  end

  defp check_usage_limit(%Coupon{max_uses: nil}), do: :ok

  defp check_usage_limit(%Coupon{id: id, max_uses: max}) do
    used = Repo.aggregate(where(CouponUsage, coupon_id: ^id), :count)
    if used < max, do: :ok, else: {:error, :usage_limit_reached}
  end

  defp check_customer_usage(%Coupon{single_use_per_customer: false}, _customer_id), do: :ok

  defp check_customer_usage(%Coupon{id: id}, customer_id) do
    already_used =
      Repo.exists?(where(CouponUsage, coupon_id: ^id, customer_id: ^customer_id))

    if already_used, do: {:error, :customer_already_used}, else: :ok
  end

  defp check_minimum_order(%Coupon{minimum_order_amount: nil}, _order), do: :ok

  defp check_minimum_order(%Coupon{minimum_order_amount: min}, %Order{total: total}) do
    if Decimal.compare(total, min) in [:gt, :eq] do
      :ok
    else
      {:error, :minimum_order_not_met}
    end
  end

  defp apply_discount(%Coupon{discount_type: :percentage, discount_value: pct} = coupon, order, customer_id) do
    amount = Decimal.mult(order.total, Decimal.div(pct, Decimal.new("100")))
    record_and_build_application(coupon, order, customer_id, Decimal.round(amount, 2))
  end

  defp apply_discount(%Coupon{discount_type: :fixed, discount_value: amount} = coupon, order, customer_id) do
    capped = Decimal.min(amount, order.total)
    record_and_build_application(coupon, order, customer_id, capped)
  end

  defp record_and_build_application(coupon, order, customer_id, discount_amount) do
    usage_attrs = %{coupon_id: coupon.id, customer_id: customer_id, order_id: order.id, redeemed_at: DateTime.utc_now()}

    with {:ok, _usage} <- %CouponUsage{} |> CouponUsage.changeset(usage_attrs) |> Repo.insert() do
      {:ok, %DiscountApplication{coupon: coupon, order_id: order.id, discount_amount: discount_amount}}
    end
  end
end
```
