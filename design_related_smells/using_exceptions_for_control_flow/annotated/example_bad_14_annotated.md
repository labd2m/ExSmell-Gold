# Code Smell Example — Annotated

## Metadata

- **Smell name:** Using exceptions for control-flow
- **Expected smell location:** `Subscriptions.PlanUpgrader.upgrade/3`
- **Affected function(s):** `Subscriptions.PlanUpgrader.upgrade/3` (library side); `Subscriptions.UpgradeRequestHandler.handle/2` (client side)
- **Explanation:** `upgrade/3` raises `RuntimeError` for predictable upgrade-denial reasons: unknown target plan, attempting to downgrade via the upgrade path, subscription not in an upgradable state, and payment method missing. These are expected domain conditions in any subscription system. Callers are forced into `try/rescue` to decide how to respond, which constitutes exception-based control-flow.

```elixir
defmodule Subscriptions.Plan do
  @moduledoc "Represents a subscription plan with tier and price metadata."

  @enforce_keys [:id, :name, :tier, :price_monthly, :price_annually]
  defstruct [:id, :name, :tier, :price_monthly, :price_annually, :features]

  @plans %{
    "free" => %{tier: 0, name: "Free"},
    "starter" => %{tier: 1, name: "Starter"},
    "pro" => %{tier: 2, name: "Pro"},
    "business" => %{tier: 3, name: "Business"},
    "enterprise" => %{tier: 4, name: "Enterprise"}
  }

  def tier_for(plan_id), do: get_in(@plans, [plan_id, :tier])
  def known?(plan_id), do: Map.has_key?(@plans, plan_id)
  def all_ids, do: Map.keys(@plans)
end

defmodule Subscriptions.Subscription do
  @moduledoc "A customer's active subscription record."

  @enforce_keys [:id, :account_id, :plan_id, :status, :billing_cycle, :started_at]
  defstruct [
    :id,
    :account_id,
    :plan_id,
    :status,
    :billing_cycle,
    :started_at,
    :next_renewal_at,
    :payment_method_id
  ]
end

defmodule Subscriptions.SubscriptionStore do
  @moduledoc "Stub persistence for subscriptions."

  alias Subscriptions.Subscription

  @subscriptions %{
    "sub_001" => %Subscription{
      id: "sub_001",
      account_id: "acc_1",
      plan_id: "starter",
      status: :active,
      billing_cycle: :monthly,
      started_at: DateTime.add(DateTime.utc_now(), -30 * 86_400, :second),
      payment_method_id: "pm_abc"
    },
    "sub_002" => %Subscription{
      id: "sub_002",
      account_id: "acc_2",
      plan_id: "pro",
      status: :past_due,
      billing_cycle: :annually,
      started_at: DateTime.add(DateTime.utc_now(), -90 * 86_400, :second),
      payment_method_id: nil
    }
  }

  def find(id), do: Map.fetch(@subscriptions, id)
  def update(sub), do: {:ok, sub}
end

defmodule Subscriptions.PlanUpgrader do
  @moduledoc """
  Transitions a subscription from its current plan to a higher-tier plan.
  Validates eligibility, tier order, and payment method presence before applying.
  """

  alias Subscriptions.{Plan, SubscriptionStore}
  require Logger

  @upgradable_statuses [:active, :trialing]

  # VALIDATION: SMELL START - Using exceptions for control-flow
  # VALIDATION: This is a smell because `upgrade/3` raises RuntimeError for four
  # VALIDATION: routine subscription-upgrade refusal reasons: unknown target plan,
  # VALIDATION: attempting a downgrade, subscription in a non-upgradable state,
  # VALIDATION: and missing payment method. All four are entirely expected in a
  # VALIDATION: subscription management workflow. Callers need try/rescue just to
  # VALIDATION: know why an upgrade request was denied, rather than pattern-matching
  # VALIDATION: on a structured {:error, reason} tuple.
  def upgrade(subscription_id, target_plan_id, initiated_by)
      when is_binary(subscription_id) and is_binary(target_plan_id) do
    unless Plan.known?(target_plan_id) do
      raise RuntimeError,
        message:
          "Plan '#{target_plan_id}' does not exist. " <>
            "Available plans: #{Enum.join(Plan.all_ids(), ", ")}"
    end

    {:ok, sub} = SubscriptionStore.find(subscription_id)

    unless sub.status in @upgradable_statuses do
      raise RuntimeError,
        message:
          "Subscription '#{subscription_id}' cannot be upgraded while in '#{sub.status}' status. " <>
            "Only #{inspect(@upgradable_statuses)} subscriptions can be upgraded."
    end

    current_tier = Plan.tier_for(sub.plan_id)
    target_tier = Plan.tier_for(target_plan_id)

    unless target_tier > current_tier do
      raise RuntimeError,
        message:
          "Cannot upgrade from '#{sub.plan_id}' (tier #{current_tier}) " <>
            "to '#{target_plan_id}' (tier #{target_tier}). " <>
            "Target plan must have a higher tier than the current plan."
    end

    if is_nil(sub.payment_method_id) do
      raise RuntimeError,
        message:
          "Subscription '#{subscription_id}' has no payment method on file. " <>
            "A valid payment method is required before upgrading."
    end

    updated_sub = %{sub | plan_id: target_plan_id}
    {:ok, persisted} = SubscriptionStore.update(updated_sub)

    Logger.info(
      "Subscription #{subscription_id} upgraded from #{sub.plan_id} to #{target_plan_id} " <>
        "by #{initiated_by}"
    )

    %{subscription: persisted, previous_plan: sub.plan_id, new_plan: target_plan_id}
  end
  # VALIDATION: SMELL END
end

defmodule Subscriptions.UpgradeRequestHandler do
  @moduledoc """
  Processes plan upgrade requests from the billing portal.
  Returns structured results to the web layer.
  """

  alias Subscriptions.PlanUpgrader
  require Logger

  def handle(subscription_id, %{target_plan: target_plan, requested_by: actor}) do
    # Client forced to use try/rescue because PlanUpgrader.upgrade/3 raises
    # on all denial conditions instead of returning {:error, reason}.
    try do
      result = PlanUpgrader.upgrade(subscription_id, target_plan, actor)

      {:ok,
       %{
         subscription_id: subscription_id,
         new_plan: result.new_plan,
         previous_plan: result.previous_plan
       }}
    rescue
      e in RuntimeError ->
        Logger.warning("Upgrade denied for sub=#{subscription_id}: #{e.message}")
        {:error, e.message}
    end
  end
end
```
