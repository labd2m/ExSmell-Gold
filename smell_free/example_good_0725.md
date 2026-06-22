```elixir
defmodule Billing.ProrationCalculator do
  @moduledoc """
  Pure-function calculator for subscription billing proration.

  Handles mid-cycle plan changes (upgrades and downgrades), computing the
  credit for unused time on the current plan and the charge for the remaining
  time on the new plan. All amounts are in integer cents to avoid
  floating-point rounding errors.
  """

  @type plan :: %{id: atom(), price_cents: non_neg_integer(), interval: :month | :year}
  @type proration :: %{
          credit_cents: non_neg_integer(),
          charge_cents: non_neg_integer(),
          net_cents: integer(),
          days_remaining: non_neg_integer(),
          period_days: pos_integer()
        }

  @doc """
  Calculates the proration amounts for a plan change on `change_date`.

  `period_start` and `period_end` define the current billing cycle.
  Returns the credit for unused days on the current plan and the charge
  for the remaining days on the new plan.
  """
  @spec calculate(plan(), plan(), Date.t(), Date.t(), Date.t()) :: proration()
  def calculate(current_plan, new_plan, change_date, period_start, period_end)
      when is_map(current_plan) and is_map(new_plan) do
    period_days = Date.diff(period_end, period_start)
    days_used = Date.diff(change_date, period_start)
    days_remaining = period_days - days_used

    credit_cents = prorate(current_plan.price_cents, days_remaining, period_days)
    charge_cents = prorate(new_plan.price_cents, days_remaining, period_days)

    %{
      credit_cents: credit_cents,
      charge_cents: charge_cents,
      net_cents: charge_cents - credit_cents,
      days_remaining: days_remaining,
      period_days: period_days
    }
  end

  @doc """
  Calculates the refund amount for a cancellation mid-cycle.
  Returns the pro-rated credit in cents.
  """
  @spec cancellation_credit(plan(), Date.t(), Date.t(), Date.t()) :: non_neg_integer()
  def cancellation_credit(current_plan, cancel_date, period_start, period_end) do
    period_days = Date.diff(period_end, period_start)
    days_remaining = Date.diff(period_end, cancel_date)
    prorate(current_plan.price_cents, days_remaining, period_days)
  end

  @doc """
  Computes the first invoice amount when starting a plan mid-cycle.
  """
  @spec first_invoice(plan(), Date.t(), Date.t()) :: non_neg_integer()
  def first_invoice(plan, start_date, period_end) do
    period_days = days_in_month(start_date)
    days_remaining = Date.diff(period_end, start_date)
    prorate(plan.price_cents, days_remaining, period_days)
  end

  @doc """
  Returns a human-readable breakdown of the proration for display.
  """
  @spec explain(proration(), plan(), plan()) :: String.t()
  def explain(%{credit_cents: credit, charge_cents: charge, net_cents: net, days_remaining: days, period_days: total}, current, new) do
    direction = if net > 0, do: "charge", else: "credit"

    """
    Plan change: #{current.id} → #{new.id}
    Remaining days in cycle: #{days}/#{total}
    Credit for unused #{current.id} time: #{format_cents(credit)}
    Charge for #{new.id} (#{days} days): #{format_cents(charge)}
    Net #{direction}: #{format_cents(abs(net))}
    """
    |> String.trim()
  end

  @doc """
  Returns `true` if the plan change is an upgrade (higher price per day).
  """
  @spec upgrade?(plan(), plan()) :: boolean()
  def upgrade?(current_plan, new_plan) do
    daily_rate(new_plan) > daily_rate(current_plan)
  end

  defp prorate(price_cents, days, period_days) when period_days > 0 do
    round(price_cents * days / period_days)
  end

  defp prorate(_price_cents, _days, 0), do: 0

  defp daily_rate(%{price_cents: price, interval: :month}), do: price / 30
  defp daily_rate(%{price_cents: price, interval: :year}), do: price / 365

  defp days_in_month(%Date{} = date) do
    Date.days_in_month(date)
  end

  defp format_cents(cents) when is_integer(cents) do
    dollars = div(cents, 100)
    remainder = rem(cents, 100)
    "$#{dollars}.#{String.pad_leading(to_string(remainder), 2, "0")}"
  end
end
```
