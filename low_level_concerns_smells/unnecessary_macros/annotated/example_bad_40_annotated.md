# Annotated Example – Unnecessary Macros

| Field | Value |
|---|---|
| **Smell name** | Unnecessary macros |
| **Expected smell location** | `Billing.Proration` module, `prorate/3` macro |
| **Affected function(s)** | `prorate/3` |
| **Short explanation** | `prorate/3` calculates a prorated billing amount from three runtime numeric inputs. This is straightforward arithmetic that belongs in a regular function; wrapping it in a macro introduces unneeded complexity and forces callers to add a `require` directive. |

```elixir
defmodule Billing.Proration do
  @moduledoc """
  Handles mid-cycle subscription changes by calculating prorated credits
  and charges when users upgrade, downgrade, or cancel their plans.
  """

  @days_in_month 30

  # VALIDATION: SMELL START - Unnecessary macros
  # VALIDATION: This is a smell because `prorate/3` performs a division
  # and multiplication on three numeric values that are only available at
  # runtime. The formula has no compile-time component. A `def` function
  # would express this calculation more clearly and would not require
  # callers to `require` the module before calling it.
  defmacro prorate(monthly_amount, days_used, days_in_period) do
    quote do
      amount = unquote(monthly_amount)
      used = unquote(days_used)
      period = unquote(days_in_period)
      daily_rate = amount / period
      Float.round(daily_rate * used, 2)
    end
  end
  # VALIDATION: SMELL END

  def compute_credit(subscription, change_date) do
    require Billing.Proration

    period_start = subscription.current_period_start
    period_end = subscription.current_period_end
    days_in_period = Date.diff(period_end, period_start)
    days_remaining = Date.diff(period_end, change_date)
    days_used = days_in_period - days_remaining

    credit =
      Billing.Proration.prorate(subscription.monthly_price, days_remaining, days_in_period)

    charge_so_far =
      Billing.Proration.prorate(subscription.monthly_price, days_used, days_in_period)

    %{
      subscription_id: subscription.id,
      change_date: change_date,
      period_start: period_start,
      period_end: period_end,
      days_in_period: days_in_period,
      days_used: days_used,
      days_remaining: days_remaining,
      credit: credit,
      charge_so_far: charge_so_far
    }
  end

  def compute_upgrade_charge(old_plan, new_plan, change_date, period_end) do
    require Billing.Proration

    days_remaining = Date.diff(period_end, change_date)
    days_in_period = @days_in_month

    credit = Billing.Proration.prorate(old_plan.monthly_price, days_remaining, days_in_period)
    new_charge = Billing.Proration.prorate(new_plan.monthly_price, days_remaining, days_in_period)

    net_charge = Float.round(new_charge - credit, 2)

    %{
      old_plan: old_plan.name,
      new_plan: new_plan.name,
      credit: credit,
      new_charge: new_charge,
      net_charge: max(net_charge, 0.0),
      direction: if(new_plan.monthly_price >= old_plan.monthly_price, do: :upgrade, else: :downgrade)
    }
  end

  def compute_cancellation_refund(subscription, cancel_date) do
    require Billing.Proration

    period_end = subscription.current_period_end
    days_remaining = max(Date.diff(period_end, cancel_date), 0)
    days_in_period = Date.diff(period_end, subscription.current_period_start)

    if subscription.refund_policy == :prorated do
      Billing.Proration.prorate(subscription.monthly_price, days_remaining, days_in_period)
    else
      0.0
    end
  end

  def annual_to_monthly(annual_price) do
    Float.round(annual_price / 12.0, 2)
  end

  def format_credit(amount, currency \\ "USD") do
    symbol = if currency == "USD", do: "$", else: currency
    "#{symbol}#{:erlang.float_to_binary(amount, [{:decimals, 2}])}"
  end
end
```
