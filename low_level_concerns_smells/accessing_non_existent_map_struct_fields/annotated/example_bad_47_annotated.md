# Code Smell: Accessing Non-Existent Map/Struct Fields

- **Smell name:** Accessing non-existent Map/Struct fields
- **Expected smell location:** `SaaS.SubscriptionManager.change_plan/2`, where optional plan transition fields are accessed dynamically
- **Affected function(s):** `change_plan/2`
- **Short explanation:** The function reads `:prorate`, `:effective_date`, and `:trial_end` from the transition options map using bracket access. Absent keys return `nil`, so proration is silently skipped and the effective date defaults incorrectly to `nil` instead of today, causing billing discrepancies that are invisible at the call site.

```elixir
defmodule SaaS.SubscriptionManager do
  @moduledoc """
  Manages customer subscription lifecycle: plan changes, upgrades,
  downgrades, trial conversions, and cancellations.
  Handles proration, billing cycle alignment, and seat enforcement.
  """

  require Logger

  @plans %{
    starter:    %{name: "Starter",    price_cents: 2_900,  max_seats: 5},
    growth:     %{name: "Growth",     price_cents: 9_900,  max_seats: 25},
    business:   %{name: "Business",   price_cents: 29_900, max_seats: 100},
    enterprise: %{name: "Enterprise", price_cents: 99_900, max_seats: :unlimited}
  }

  @type subscription :: %{
          id: String.t(),
          customer_id: String.t(),
          current_plan: atom(),
          seat_count: pos_integer(),
          status: :active | :trialing | :cancelled | :past_due,
          current_period_start: Date.t(),
          current_period_end: Date.t()
        }

  @type transition_opts :: %{
          target_plan: atom(),
          optional(:prorate) => boolean(),
          optional(:effective_date) => Date.t(),
          optional(:trial_end) => Date.t(),
          optional(:seat_count) => pos_integer()
        }

  @spec change_plan(subscription(), transition_opts()) ::
          {:ok, map()} | {:error, String.t()}
  def change_plan(subscription, opts) do
    with :ok <- check_subscription_status(subscription),
         :ok <- check_target_plan(opts.target_plan),
         :ok <- check_seat_count(subscription, opts) do
      apply_plan_change(subscription, opts)
    end
  end

  defp check_subscription_status(%{status: :cancelled}),
    do: {:error, "cannot change plan on a cancelled subscription"}
  defp check_subscription_status(_), do: :ok

  defp check_target_plan(plan) when is_map_key(@plans, plan), do: :ok
  defp check_target_plan(plan), do: {:error, "unknown plan: #{plan}"}

  defp check_seat_count(subscription, opts) do
    seats     = opts[:seat_count] || subscription.seat_count
    plan_info = @plans[opts.target_plan]

    case plan_info.max_seats do
      :unlimited -> :ok
      max when seats <= max -> :ok
      max -> {:error, "seat count #{seats} exceeds plan maximum of #{max}"}
    end
  end

  defp apply_plan_change(subscription, opts) do
    # VALIDATION: SMELL START - Accessing non-existent Map/Struct fields
    # VALIDATION: This is a smell because `opts[:prorate]`, `opts[:effective_date]`,
    # and `opts[:trial_end]` use dynamic bracket access on a plain map. When any key
    # is absent, `nil` is returned. A missing `:prorate` key is treated as falsy,
    # silently disabling proration even when the caller intended to omit only
    # unrelated fields. A missing `:effective_date` becomes `nil`, and `nil` is then
    # used as the new period start date — an invalid value that propagates downstream
    # to billing without raising an error at the point of the bad access.
    prorate        = opts[:prorate]
    effective_date = opts[:effective_date]
    trial_end      = opts[:trial_end]
    # VALIDATION: SMELL END

    today            = Date.utc_today()
    start_date       = effective_date || today
    new_plan_info    = @plans[opts.target_plan]
    old_plan_info    = @plans[subscription.current_plan]
    new_seat_count   = opts[:seat_count] || subscription.seat_count

    proration_credit =
      if prorate and start_date == today do
        compute_proration(subscription, old_plan_info, new_plan_info)
      else
        0
      end

    new_period_end =
      if trial_end do
        trial_end
      else
        Date.add(start_date, 30)
      end

    updated = %{
      subscription_id:      subscription.id,
      customer_id:          subscription.customer_id,
      previous_plan:        subscription.current_plan,
      new_plan:             opts.target_plan,
      seat_count:           new_seat_count,
      status:               :active,
      current_period_start: start_date,
      current_period_end:   new_period_end,
      proration_credit:     proration_credit,
      changed_at:           DateTime.utc_now()
    }

    Logger.info("Subscription #{subscription.id} changed from #{subscription.current_plan} to #{opts.target_plan}")
    {:ok, updated}
  end

  defp compute_proration(subscription, old_plan, new_plan) do
    remaining_days = Date.diff(subscription.current_period_end, Date.utc_today())
    period_days    = Date.diff(subscription.current_period_end, subscription.current_period_start)
    daily_rate     = old_plan.price_cents / max(period_days, 1)
    credit         = round(daily_rate * remaining_days)
    charge         = new_plan.price_cents
    max(charge - credit, 0)
  end

  @spec cancel(subscription(), String.t()) :: {:ok, map()}
  def cancel(subscription, reason) do
    Logger.info("Subscription #{subscription.id} cancelled: #{reason}")
    {:ok, %{subscription | status: :cancelled}}
  end
end
```
