```elixir
defmodule Subscriptions.PlanChanger do
  @moduledoc """
  Handles plan upgrade, downgrade, and cross-cycle change requests for
  SaaS subscriptions. Applies proration, updates the billing provider,
  and emits domain events for downstream services.
  """

  require Logger

  alias Subscriptions.{
    BillingGateway,
    ProrationCalculator,
    EntitlementEngine,
    SubscriptionRepo,
    EventBus,
    AuditLog,
    CustomerMailer
  }

  @plan_hierarchy %{starter: 1, growth: 2, business: 3, enterprise: 4}

  def apply_change(%Subscriptions.ChangeRequest{
        subscription_id: subscription_id,
        account_id: account_id,
        seats: seats,
        billing_interval: billing_interval,
        coupon_code: coupon_code,
        current_plan: current_plan,
        target_plan: target_plan,
        billing_cycle_end: billing_cycle_end
      })
      when is_map_key(@plan_hierarchy, current_plan) and
             is_map_key(@plan_hierarchy, target_plan) and
             @plan_hierarchy[target_plan] > @plan_hierarchy[current_plan] and
             billing_cycle_end > :os.system_time(:second) do
    Logger.info(
      "[PlanChanger] Upgrading subscription #{subscription_id} for account #{account_id}: " <>
        "#{current_plan} -> #{target_plan} (#{seats} seats, #{billing_interval})"
    )

    proration = ProrationCalculator.calculate(subscription_id, current_plan, target_plan, billing_cycle_end)

    with {:ok, charge} <- BillingGateway.charge_proration(account_id, proration, coupon_code),
         {:ok, _} <- SubscriptionRepo.update_plan(subscription_id, target_plan, seats),
         :ok <- EntitlementEngine.upgrade(account_id, current_plan, target_plan),
         :ok <- EventBus.publish(:plan_upgraded, %{
                  subscription_id: subscription_id,
                  account_id: account_id,
                  from: current_plan,
                  to: target_plan,
                  charge: charge
                }),
         :ok <- CustomerMailer.send_upgrade_confirmation(account_id, target_plan, seats),
         :ok <- AuditLog.write(:plan_changed, account_id, %{
                  subscription_id: subscription_id,
                  from: current_plan,
                  to: target_plan,
                  proration: proration,
                  billing_interval: billing_interval
                }) do
      {:ok, :upgraded, target_plan}
    else
      {:error, :payment_failed} = err ->
        Logger.warning("[PlanChanger] Proration charge failed for #{subscription_id}")
        err

      {:error, reason} ->
        Logger.error("[PlanChanger] Upgrade failed for #{subscription_id}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  def apply_change(%Subscriptions.ChangeRequest{
        subscription_id: subscription_id,
        account_id: account_id,
        seats: seats,
        billing_interval: billing_interval,
        coupon_code: _coupon_code,
        current_plan: current_plan,
        target_plan: target_plan,
        billing_cycle_end: billing_cycle_end
      })
      when is_map_key(@plan_hierarchy, current_plan) and
             is_map_key(@plan_hierarchy, target_plan) and
             @plan_hierarchy[target_plan] < @plan_hierarchy[current_plan] and
             billing_cycle_end > :os.system_time(:second) do
    Logger.info(
      "[PlanChanger] Scheduling downgrade for #{subscription_id}: " <>
        "#{current_plan} -> #{target_plan} at cycle end"
    )

    with :ok <- validate_seats_for_plan(target_plan, seats),
         {:ok, _} <- SubscriptionRepo.schedule_downgrade(subscription_id, target_plan, billing_cycle_end),
         :ok <- EntitlementEngine.lock_new_features(account_id, target_plan),
         :ok <- EventBus.publish(:plan_downgrade_scheduled, %{
                  subscription_id: subscription_id,
                  account_id: account_id,
                  from: current_plan,
                  to: target_plan,
                  effective_at: billing_cycle_end
                }),
         :ok <- CustomerMailer.send_downgrade_scheduled_notice(account_id, target_plan, billing_cycle_end),
         :ok <- AuditLog.write(:downgrade_scheduled, account_id, %{
                  subscription_id: subscription_id,
                  from: current_plan,
                  to: target_plan,
                  billing_interval: billing_interval
                }) do
      {:ok, :downgrade_scheduled, billing_cycle_end}
    else
      {:error, :seats_exceed_plan_limit} ->
        Logger.warning("[PlanChanger] Seat count #{seats} exceeds limit for #{target_plan}")
        {:error, :seats_exceed_plan_limit}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def apply_change(%Subscriptions.ChangeRequest{
        subscription_id: subscription_id,
        account_id: account_id,
        seats: seats,
        billing_interval: billing_interval,
        coupon_code: coupon_code,
        current_plan: same_plan,
        target_plan: same_plan,
        billing_cycle_end: billing_cycle_end
      })
      when billing_cycle_end > :os.system_time(:second) do
    Logger.info(
      "[PlanChanger] Seat count adjustment on #{subscription_id} for account #{account_id}: " <>
        "plan #{same_plan}, new seat count #{seats}"
    )

    with {:ok, seat_delta_charge} <-
           BillingGateway.charge_seat_adjustment(account_id, same_plan, seats, billing_cycle_end, coupon_code),
         {:ok, _} <- SubscriptionRepo.update_seats(subscription_id, seats),
         :ok <- EntitlementEngine.adjust_seats(account_id, seats),
         :ok <- EventBus.publish(:seats_adjusted, %{
                  subscription_id: subscription_id,
                  account_id: account_id,
                  plan: same_plan,
                  new_seats: seats,
                  charge: seat_delta_charge
                }),
         :ok <- AuditLog.write(:seats_adjusted, account_id, %{
                  subscription_id: subscription_id,
                  plan: same_plan,
                  new_seats: seats,
                  billing_interval: billing_interval
                }) do
      {:ok, :seats_updated, seats}
    else
      {:error, reason} ->
        Logger.error("[PlanChanger] Seat adjustment failed for #{subscription_id}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  def apply_change(%Subscriptions.ChangeRequest{
        subscription_id: sid,
        billing_cycle_end: bce
      })
      when bce <= :os.system_time(:second) do
    Logger.warning("[PlanChanger] Change request rejected for #{sid}: billing cycle already expired")
    {:error, :cycle_expired}
  end

  def apply_change(%Subscriptions.ChangeRequest{subscription_id: sid}) do
    Logger.error("[PlanChanger] No matching change handler for request on #{sid}")
    {:error, :unhandled_change_request}
  end

  # --- Private helpers ---

  @plan_seat_limits %{starter: 5, growth: 25, business: 100, enterprise: :unlimited}

  defp validate_seats_for_plan(plan, seats) do
    case Map.get(@plan_seat_limits, plan) do
      :unlimited -> :ok
      limit when seats <= limit -> :ok
      _ -> {:error, :seats_exceed_plan_limit}
    end
  end
end
```
