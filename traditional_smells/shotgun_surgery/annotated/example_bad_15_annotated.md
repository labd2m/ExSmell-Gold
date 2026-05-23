# Example Bad 15 — Annotated

## Metadata

- **Smell Name**: Shotgun Surgery
- **Expected Smell Location**: Functions `calculate_overage_charge/2`, `get_throttle_speed_kbps/1`, `get_roaming_rate_per_mb/1`, and `get_priority_level/1` inside `Telecom.PlanManager`
- **Affected Functions**: `calculate_overage_charge/2`, `get_throttle_speed_kbps/1`, `get_roaming_rate_per_mb/1`, `get_priority_level/1`
- **Explanation**: The data plan logic (`:prepaid`, `:postpaid`, `:unlimited`) is scattered across four separate functions. Adding a new plan type (e.g., `:business`) would require four separate, independent changes across the module, characteristic of Shotgun Surgery.

```elixir
defmodule Telecom.PlanManager do
  @moduledoc """
  Manages subscriber data plan policies including overage billing,
  throttle speed enforcement, roaming rates, and network
  priority assignment for different plan types.
  """

  alias Telecom.{
    Subscription, UsageRecord, BillingCycle,
    NetworkPolicy, RoamingGateway, SubscriberNotifier
  }

  def evaluate_usage(%Subscription{} = sub, %UsageRecord{} = usage) do
    with {:ok, sub} <- check_and_apply_overage(sub, usage),
         :ok        <- enforce_throttle_if_needed(sub, usage),
         :ok        <- NetworkPolicy.update_priority(sub.subscriber_id, get_priority_level(sub.plan_type)) do
      {:ok, sub}
    end
  end

  defp check_and_apply_overage(%Subscription{} = sub, %UsageRecord{data_mb: used_mb}) do
    over_mb = max(0, used_mb - sub.data_allowance_mb)

    if over_mb > 0 do
      charge = calculate_overage_charge(over_mb, sub.plan_type)
      updated = %{sub | overage_charge: sub.overage_charge + charge}
      SubscriberNotifier.warn_overage(sub.subscriber_id, over_mb, charge)
      BillingCycle.record_overage(sub.id, charge)
      {:ok, updated}
    else
      {:ok, sub}
    end
  end

  defp enforce_throttle_if_needed(%Subscription{} = sub, %UsageRecord{data_mb: used_mb}) do
    if used_mb >= sub.data_allowance_mb do
      speed = get_throttle_speed_kbps(sub.plan_type)
      NetworkPolicy.throttle(sub.subscriber_id, speed)
      SubscriberNotifier.notify_throttled(sub.subscriber_id, speed)
    else
      :ok
    end
  end

  def calculate_roaming_bill(%Subscription{} = sub, roaming_usage_mb) do
    rate  = get_roaming_rate_per_mb(sub.plan_type)
    total = Float.round(roaming_usage_mb * rate, 2)
    RoamingGateway.record_charge(sub.id, total)
    {:ok, total}
  end

  # VALIDATION: SMELL START - Shotgun Surgery [location 1 of 4]
  # VALIDATION: This is a smell because adding a new plan type (e.g., :business)
  # requires a new clause here AND in get_throttle_speed_kbps/1, get_roaming_rate_per_mb/1,
  # and get_priority_level/1 — four scattered changes for one new plan type.
  def calculate_overage_charge(over_mb, :prepaid) do
    Float.round(over_mb * 0.05, 2)
  end

  def calculate_overage_charge(_over_mb, :postpaid) do
    0.00
  end

  def calculate_overage_charge(_over_mb, :unlimited) do
    0.00
  end

  def calculate_overage_charge(over_mb, _plan_type) do
    Float.round(over_mb * 0.08, 2)
  end
  # VALIDATION: SMELL END [location 1 of 4]

  # VALIDATION: SMELL START - Shotgun Surgery [location 2 of 4]
  # VALIDATION: This is a smell because a new plan type also requires a throttle speed
  # clause here, independent of calculate_overage_charge/2.
  def get_throttle_speed_kbps(:prepaid),   do: 64
  def get_throttle_speed_kbps(:postpaid),  do: 512
  def get_throttle_speed_kbps(:unlimited), do: 1_024
  def get_throttle_speed_kbps(_),          do: 128
  # VALIDATION: SMELL END [location 2 of 4]

  # VALIDATION: SMELL START - Shotgun Surgery [location 3 of 4]
  # VALIDATION: This is a smell because a new plan type also requires a roaming rate
  # clause here, independent of the previous two locations.
  def get_roaming_rate_per_mb(:prepaid),   do: 0.25
  def get_roaming_rate_per_mb(:postpaid),  do: 0.10
  def get_roaming_rate_per_mb(:unlimited), do: 0.05
  def get_roaming_rate_per_mb(_),          do: 0.30
  # VALIDATION: SMELL END [location 3 of 4]

  # VALIDATION: SMELL START - Shotgun Surgery [location 4 of 4]
  # VALIDATION: This is a smell because a new plan type also requires a network priority
  # clause here, completing the four-location change for every new plan type.
  def get_priority_level(:prepaid),   do: :low
  def get_priority_level(:postpaid),  do: :medium
  def get_priority_level(:unlimited), do: :high
  def get_priority_level(_),          do: :low
  # VALIDATION: SMELL END [location 4 of 4]

  def reset_monthly_usage(%Subscription{} = sub) do
    updated = %{sub | overage_charge: 0.0, cycle_start: Date.utc_today()}
    NetworkPolicy.restore_speed(sub.subscriber_id)
    BillingCycle.close(sub.id)
    {:ok, updated}
  end

  def upgrade_plan(%Subscription{} = sub, new_plan_type) do
    updated = %{sub |
      plan_type:       new_plan_type,
      upgraded_at:     DateTime.utc_now()
    }

    NetworkPolicy.update_priority(sub.subscriber_id, get_priority_level(new_plan_type))
    {:ok, updated}
  end

  def list_available_plans do
    [:prepaid, :postpaid, :unlimited]
  end
end
```
