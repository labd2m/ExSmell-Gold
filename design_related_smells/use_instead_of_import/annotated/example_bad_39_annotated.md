# Code Smell: "Use" instead of "import"

## Metadata

- **Smell name:** "Use" instead of "import"
- **Expected smell location:** `SubscriptionManager` module, top-level directive
- **Affected function(s):** `activate/2`, `cancel/2`, `change_plan/3`, `renewal_preview/1`
- **Short explanation:** `SubscriptionManager` calls `use PlanHelpers` to obtain plan-comparison and grace-period utilities. The `__using__/1` macro of `PlanHelpers` silently injects an `import` of `IntervalUtils` into `SubscriptionManager`, propagating hidden access to functions like `add_interval/3`, `interval_days/1`, and `within_grace?/2`. A developer reading `SubscriptionManager` will see these functions used as if they are local, but their origin is invisible without inspecting `PlanHelpers`. Replacing `use PlanHelpers` with `import PlanHelpers` would make all dependencies explicit.

---

```elixir
defmodule IntervalUtils do
  def add_interval(date, :monthly, n), do: Date.add(date, n * 30)
  def add_interval(date, :yearly, n),  do: Date.add(date, n * 365)
  def add_interval(date, :weekly, n),  do: Date.add(date, n * 7)
  def add_interval(date, :daily, n),   do: Date.add(date, n)

  def interval_days(:monthly), do: 30
  def interval_days(:yearly),  do: 365
  def interval_days(:weekly),  do: 7
  def interval_days(:daily),   do: 1

  def within_grace?(cancelled_at, grace_days) do
    grace_end = Date.add(cancelled_at, grace_days)
    Date.compare(Date.utc_today(), grace_end) != :gt
  end

  def overlaps?(start_a, end_a, start_b, end_b) do
    Date.compare(start_a, end_b) == :lt and
    Date.compare(end_a, start_b) == :gt
  end
end

defmodule PlanHelpers do
  defmacro __using__(_opts) do
    quote do
      # VALIDATION: SMELL START - "Use" instead of "import"
      # VALIDATION: This is a smell because __using__/1 injects `import IntervalUtils`
      # VALIDATION: into SubscriptionManager. add_interval/3, interval_days/1,
      # VALIDATION: within_grace?/2, and overlaps?/4 all appear in SubscriptionManager
      # VALIDATION: without any visible import statement for IntervalUtils.
      # VALIDATION: To understand the full dependency surface of SubscriptionManager,
      # VALIDATION: a reader must inspect PlanHelpers internals — a clear readability
      # VALIDATION: problem. Using `import PlanHelpers` at the call site would be
      # VALIDATION: transparent and avoid this hidden propagation.
      import IntervalUtils
      # VALIDATION: SMELL END

      def upgrade?(current_plan, new_plan), do: new_plan.price > current_plan.price
      def downgrade?(current_plan, new_plan), do: new_plan.price < current_plan.price

      def prorate(amount, days_used, total_days) when total_days > 0 do
        Float.round(amount * (total_days - days_used) / total_days, 2)
      end
      def prorate(amount, _used, _total), do: amount

      def plan_label(%{interval: :monthly, name: n}), do: "#{n} (Monthly)"
      def plan_label(%{interval: :yearly,  name: n}), do: "#{n} (Annual)"
      def plan_label(%{name: n}), do: n
    end
  end
end

defmodule SubscriptionManager do
  use PlanHelpers

  @grace_period_days 3
  @trial_days        14

  def activate(user, plan) do
    today     = Date.utc_today()
    trial_end = add_interval(today, :daily, @trial_days)
    period_end = add_interval(today, plan.interval, 1)

    {:ok, %{
      id:             "sub_#{:erlang.unique_integer([:positive])}",
      user_id:        user.id,
      plan_id:        plan.id,
      plan_label:     plan_label(plan),
      status:         :trialing,
      trial_ends_at:  trial_end,
      current_period_start: today,
      current_period_end:   period_end,
      interval_days:  interval_days(plan.interval),
      activated_at:   DateTime.utc_now()
    }}
  end

  def cancel(subscription, opts \\ []) do
    immediate = Keyword.get(opts, :immediate, false)

    cond do
      immediate ->
        {:ok, %{subscription | status: :cancelled, cancelled_at: Date.utc_today()}}

      subscription.status == :cancelled ->
        {:error, :already_cancelled}

      true ->
        {:ok, %{subscription |
          status:            :cancel_pending,
          cancel_at_period_end: true,
          cancellation_requested_at: DateTime.utc_now()
        }}
    end
  end

  def change_plan(subscription, current_plan, new_plan) do
    today     = Date.utc_today()
    days_used = Date.diff(today, subscription.current_period_start)
    total_days = interval_days(current_plan.interval)
    credit    = prorate(current_plan.price, days_used, total_days)

    direction =
      cond do
        upgrade?(current_plan, new_plan)   -> :upgrade
        downgrade?(current_plan, new_plan) -> :downgrade
        true                               -> :lateral
      end

    new_period_end = add_interval(today, new_plan.interval, 1)

    {:ok, %{
      subscription |
      plan_id:              new_plan.id,
      plan_label:           plan_label(new_plan),
      current_period_start: today,
      current_period_end:   new_period_end,
      interval_days:        interval_days(new_plan.interval),
      change_direction:     direction,
      prorated_credit:      credit,
      changed_at:           DateTime.utc_now()
    }}
  end

  def renewal_preview(subscription, plan) do
    next_start = subscription.current_period_end
    next_end   = add_interval(next_start, plan.interval, 1)

    %{
      subscription_id: subscription.id,
      plan_label:      plan_label(plan),
      renewal_date:    next_start,
      next_period_end: next_end,
      amount_due:      plan.price,
      interval_days:   interval_days(plan.interval)
    }
  end

  def reactivate(subscription) do
    cond do
      subscription.status == :active ->
        {:error, :already_active}

      subscription.status == :cancelled and
      within_grace?(subscription.cancelled_at, @grace_period_days) ->
        {:ok, %{subscription | status: :active, cancelled_at: nil}}

      true ->
        {:error, :grace_period_expired}
    end
  end

  def list_active(subscriptions) do
    Enum.filter(subscriptions, &(&1.status in [:active, :trialing]))
  end
end
```
