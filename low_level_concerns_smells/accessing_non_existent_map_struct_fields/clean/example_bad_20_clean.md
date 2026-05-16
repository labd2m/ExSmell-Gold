```elixir
defmodule Subscription.PlanUpgrader do
  @moduledoc """
  Handles plan upgrade requests for subscription accounts, computes
  proration credits, and schedules billing adjustments.
  """

  require Logger

  @valid_plans    ~w(starter growth professional enterprise)
  @valid_cycles   [:monthly, :annual]
  @annual_discount 0.20

  @plan_prices %{
    "starter"      => 29.00,
    "growth"       => 79.00,
    "professional" => 149.00,
    "enterprise"   => 399.00
  }

  @type upgrade_result :: %{
          subscription_id: String.t(),
          previous_plan: String.t(),
          new_plan: String.t(),
          billing_cycle: atom(),
          new_monthly_price: float(),
          proration_credit: float(),
          effective_at: DateTime.t()
        }

  @spec upgrade(map(), map(), map()) ::
          {:ok, upgrade_result()} | {:error, String.t()}
  def upgrade(subscription, upgrade_request, account) do
    target_plan   = upgrade_request[:target_plan]
    billing_cycle = upgrade_request[:billing_cycle]
    prorate       = upgrade_request[:prorate]

    with :ok <- validate_plan(target_plan),
         :ok <- validate_upgrade_path(subscription.current_plan, target_plan),
         :ok <- validate_billing_cycle(billing_cycle) do
      cycle          = billing_cycle || subscription.billing_cycle
      base_price     = Map.fetch!(@plan_prices, target_plan)
      monthly_price  = adjusted_price(base_price, cycle)

      proration_credit =
        if prorate do
          compute_proration(subscription, base_price)
        else
          0.0
        end

      effective_at = next_billing_date(subscription, prorate)

      result = %{
        subscription_id: subscription.id,
        previous_plan: subscription.current_plan,
        new_plan: target_plan,
        billing_cycle: cycle,
        new_monthly_price: monthly_price,
        proration_credit: proration_credit,
        effective_at: effective_at
      }

      Logger.info("Subscription upgraded",
        subscription_id: subscription.id,
        from: subscription.current_plan,
        to: target_plan,
        proration_credit: proration_credit,
        account_id: account.id
      )

      {:ok, result}
    end
  end

  # ── Helpers ─────────────────────────────────────────────────────────────────

  defp adjusted_price(base, :annual),  do: Float.round(base * (1 - @annual_discount), 2)
  defp adjusted_price(base, :monthly), do: base
  defp adjusted_price(base, _),        do: base

  defp compute_proration(subscription, new_base_price) do
    now            = DateTime.utc_now()
    period_end     = subscription.current_period_end
    total_seconds  = DateTime.diff(period_end, subscription.current_period_start)
    remaining_secs = DateTime.diff(period_end, now)
    remaining_frac = remaining_secs / max(total_seconds, 1)

    old_price     = Map.fetch!(@plan_prices, subscription.current_plan)
    credit        = old_price * remaining_frac
    upgrade_cost  = new_base_price * remaining_frac

    Float.round(max(upgrade_cost - credit, 0.0), 2)
  end

  defp next_billing_date(subscription, prorate) do
    if prorate do
      DateTime.utc_now()
    else
      subscription.current_period_end
    end
  end

  # ── Validators ──────────────────────────────────────────────────────────────

  defp validate_plan(nil), do: {:error, "Target plan is required"}

  defp validate_plan(plan) when plan in @valid_plans, do: :ok

  defp validate_plan(plan),
    do: {:error, "Invalid plan: #{plan}. Valid: #{Enum.join(@valid_plans, ", ")}"}

  defp validate_upgrade_path(current, target) do
    current_idx = Enum.find_index(@valid_plans, &(&1 == current))
    target_idx  = Enum.find_index(@valid_plans, &(&1 == target))

    cond do
      is_nil(current_idx) -> {:error, "Unknown current plan: #{current}"}
      is_nil(target_idx)  -> {:error, "Unknown target plan: #{target}"}
      target_idx <= current_idx -> {:error, "Target plan must be higher than current plan"}
      true -> :ok
    end
  end

  defp validate_billing_cycle(nil), do: :ok

  defp validate_billing_cycle(c) when c in @valid_cycles, do: :ok

  defp validate_billing_cycle(c),
    do: {:error, "Invalid billing cycle: #{inspect(c)}"}
end
```
