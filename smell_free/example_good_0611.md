# File: `example_good_611.md`

```elixir
defmodule Billing.ProrationCalculator do
  @moduledoc """
  Computes prorated billing adjustments for mid-cycle subscription
  changes such as plan upgrades, downgrades, and cancellations.

  All arithmetic uses integer cents and day-level granularity to keep
  results reproducible. The calculator is purely functional and performs
  no I/O; callers supply the billing context and receive credit and
  charge amounts to record against an invoice.
  """

  @type amount_cents :: integer()

  @type billing_period :: %{
          required(:start_date) => Date.t(),
          required(:end_date) => Date.t()
        }

  @type plan :: %{
          required(:id) => String.t(),
          required(:amount_cents) => pos_integer(),
          required(:name) => String.t()
        }

  @type proration_result :: %{
          credit_cents: non_neg_integer(),
          charge_cents: non_neg_integer(),
          net_cents: integer(),
          days_remaining: non_neg_integer(),
          days_in_period: pos_integer(),
          description: String.t()
        }

  @doc """
  Calculates the proration adjustments for switching from `old_plan`
  to `new_plan` on `change_date` within `period`.

  Returns a `proration_result` with the credit for unused days on the
  old plan and the charge for remaining days on the new plan.
  """
  @spec calculate_change(plan(), plan(), billing_period(), Date.t()) ::
          {:ok, proration_result()} | {:error, :change_date_outside_period}
  def calculate_change(%{} = old_plan, %{} = new_plan, %{} = period, %Date{} = change_date) do
    with :ok <- validate_date_in_period(change_date, period) do
      period_days = Date.diff(period.end_date, period.start_date)
      days_remaining = Date.diff(period.end_date, change_date)
      days_elapsed = period_days - days_remaining

      daily_old = old_plan.amount_cents / period_days
      daily_new = new_plan.amount_cents / period_days

      credit_cents = round(daily_old * days_remaining)
      charge_cents = round(daily_new * days_remaining)
      net_cents = charge_cents - credit_cents

      description = build_description(old_plan, new_plan, change_date, days_remaining, days_elapsed)

      {:ok, %{
        credit_cents: credit_cents,
        charge_cents: charge_cents,
        net_cents: net_cents,
        days_remaining: days_remaining,
        days_in_period: period_days,
        description: description
      }}
    end
  end

  @doc """
  Calculates the refund amount for cancelling a subscription on `cancel_date`.

  Returns `{:ok, refund_cents}` or `{:error, :cancel_date_outside_period}`.
  """
  @spec calculate_cancellation(plan(), billing_period(), Date.t()) ::
          {:ok, non_neg_integer()} | {:error, :cancel_date_outside_period}
  def calculate_cancellation(%{} = plan, %{} = period, %Date{} = cancel_date) do
    with :ok <- validate_date_in_period(cancel_date, period) do
      period_days = Date.diff(period.end_date, period.start_date)
      days_remaining = Date.diff(period.end_date, cancel_date)
      daily_rate = plan.amount_cents / period_days
      refund = round(daily_rate * days_remaining)
      {:ok, max(refund, 0)}
    end
  end

  @doc """
  Computes the charge for adding a new plan feature on `start_date`
  for the remainder of the current billing period.
  """
  @spec calculate_add_on(plan(), billing_period(), Date.t()) ::
          {:ok, non_neg_integer()} | {:error, :start_date_outside_period}
  def calculate_add_on(%{} = add_on_plan, %{} = period, %Date{} = start_date) do
    with :ok <- validate_date_in_period(start_date, period) do
      period_days = Date.diff(period.end_date, period.start_date)
      days_remaining = Date.diff(period.end_date, start_date)
      daily_rate = add_on_plan.amount_cents / period_days
      charge = round(daily_rate * days_remaining)
      {:ok, max(charge, 0)}
    end
  end

  @doc """
  Returns the daily rate in cents for a plan within a billing period.
  """
  @spec daily_rate(plan(), billing_period()) :: float()
  def daily_rate(%{amount_cents: amount}, %{start_date: start_d, end_date: end_d}) do
    period_days = Date.diff(end_d, start_d)
    if period_days > 0, do: amount / period_days, else: 0.0
  end

  defp validate_date_in_period(date, %{start_date: start_d, end_date: end_d}) do
    after_start = Date.compare(date, start_d) != :lt
    before_end = Date.compare(date, end_d) != :gt

    if after_start and before_end do
      :ok
    else
      {:error, :change_date_outside_period}
    end
  end

  defp build_description(old_plan, new_plan, change_date, days_remaining, days_elapsed) do
    "Plan change from #{old_plan.name} to #{new_plan.name} on #{Date.to_iso8601(change_date)}: " <>
      "#{days_elapsed} days used, #{days_remaining} days remaining"
  end
end
```
