# Example Bad 10 — Annotated

## Metadata

- **Smell Name**: Speculative Generality
- **Expected Smell Location**: `Billing.DiscountEngine.apply_discount/1`
- **Affected Function(s)**: `apply_discount/1`
- **Explanation**: `apply_discount/1` pattern-matches on `subscription.plan_type`
  expecting that different plan tiers would eventually receive different discount rates.
  The `case` expression contains only a single catch-all clause (`_`) that applies the
  same 20 % discount regardless of the plan type. The per-tier branching structure is
  purely speculative — it was designed for differentiation that was never implemented.

## Code

```elixir
defmodule Billing.DiscountEngine do
  @moduledoc """
  Applies promotional and plan-based discounts to subscription renewals
  and one-time charges. Coordinates with the coupon registry and
  eligibility rules before modifying invoice amounts.
  """

  alias Billing.{Subscription, Coupon, Invoice, DiscountLog}
  alias Billing.Repo

  @base_discount_rate 0.20

  def apply_discount(%Subscription{plan_type: plan_type} = subscription) do
    # VALIDATION: SMELL START - Speculative Generality
    # VALIDATION: This is a smell because `plan_type` is extracted via pattern
    # matching to allow different discount rates per subscription tier (e.g.
    # :starter, :professional, :enterprise). The case has only a catch-all clause
    # that returns the same @base_discount_rate for every plan type. The per-tier
    # structure is speculative and was never filled with differentiated rates.
    discount_rate =
      case plan_type do
        _ -> @base_discount_rate
      end
    # VALIDATION: SMELL END

    discounted_amount = Float.round(subscription.monthly_price * (1 - discount_rate), 2)

    attrs = %{
      subscription_id: subscription.id,
      original_amount: subscription.monthly_price,
      discount_rate:   discount_rate,
      final_amount:    discounted_amount,
      applied_at:      DateTime.utc_now()
    }

    case DiscountLog.changeset(%DiscountLog{}, attrs) |> Repo.insert() do
      {:ok, log} -> {:ok, %{amount: discounted_amount, log_id: log.id}}
      {:error, cs} -> {:error, cs}
    end
  end

  def apply_coupon(subscription_id, coupon_code) do
    coupon = Repo.get_by!(Coupon, code: coupon_code)

    cond do
      not coupon.active ->
        {:error, :coupon_inactive}

      coupon_expired?(coupon) ->
        {:error, :coupon_expired}

      exceeds_usage_limit?(coupon) ->
        {:error, :usage_limit_reached}

      true ->
        subscription = Repo.get!(Subscription, subscription_id)
        discounted = apply_coupon_value(subscription.monthly_price, coupon)

        subscription
        |> Subscription.changeset(%{
          monthly_price: discounted,
          coupon_id:     coupon.id,
          discount_note: "Coupon #{coupon_code} applied"
        })
        |> Repo.update()
    end
  end

  def bulk_apply_discounts(subscription_ids) do
    results =
      Enum.map(subscription_ids, fn id ->
        subscription = Repo.get!(Subscription, id)
        {id, apply_discount(subscription)}
      end)

    {successes, failures} =
      Enum.split_with(results, fn {_id, result} -> match?({:ok, _}, result) end)

    %{applied: length(successes), failed: length(failures), details: results}
  end

  def remove_discount(subscription_id) do
    subscription = Repo.get!(Subscription, subscription_id)
    original     = subscription.base_price

    subscription
    |> Subscription.changeset(%{
      monthly_price: original,
      coupon_id:     nil,
      discount_note: nil
    })
    |> Repo.update()
  end

  def discount_summary(from_date, to_date) do
    DiscountLog
    |> Repo.all()
    |> Enum.filter(fn log ->
      DateTime.compare(log.applied_at, from_date) in [:gt, :eq] and
        DateTime.compare(log.applied_at, to_date) in [:lt, :eq]
    end)
    |> Enum.reduce(%{count: 0, total_savings: 0.0}, fn log, acc ->
      savings = log.original_amount - log.final_amount
      %{acc | count: acc.count + 1, total_savings: acc.total_savings + savings}
    end)
    |> Map.update!(:total_savings, &Float.round(&1, 2))
  end

  def eligible_for_discount?(subscription) do
    subscription.status == :active and
      subscription.months_active >= 3 and
      is_nil(subscription.coupon_id)
  end

  # --- Private ---

  defp coupon_expired?(%Coupon{expires_at: nil}), do: false
  defp coupon_expired?(%Coupon{expires_at: expires_at}) do
    DateTime.compare(expires_at, DateTime.utc_now()) == :lt
  end

  defp exceeds_usage_limit?(%Coupon{max_uses: nil}), do: false
  defp exceeds_usage_limit?(%Coupon{max_uses: max, used_count: used}), do: used >= max

  defp apply_coupon_value(price, %Coupon{discount_type: :percent, value: pct}) do
    Float.round(price * (1 - pct / 100), 2)
  end

  defp apply_coupon_value(price, %Coupon{discount_type: :fixed, value: amount}) do
    Float.round(max(0.0, price - amount), 2)
  end
end
```
