```elixir
defmodule PlanUpgradePolicy do
  @moduledoc """
  Evaluates whether a subscription plan change is allowed given the current
  subscription state, billing cycle position, and business rules.
  """

  defmodule DowngradeNotAllowedError do
    defexception [:message, :current_plan, :requested_plan]
  end

  defmodule MidCycleLockError do
    defexception [:message, :subscription_id, :cycle_ends_at]
  end

  defmodule UnsupportedTransitionError do
    defexception [:message, :from_plan, :to_plan]
  end

  defmodule SameplanError do
    defexception [:message, :plan]
  end

  defmodule InactiveSubscriptionError do
    defexception [:message, :subscription_id, :status]
  end

  @plan_rank %{free: 0, starter: 1, pro: 2, enterprise: 3}

  @allowed_transitions %{
    free: [:starter, :pro, :enterprise],
    starter: [:pro, :enterprise],
    pro: [:enterprise],
    enterprise: []
  }

  def evaluate(%{id: sub_id, plan: current_plan, status: status, cycle_ends_at: cycle_ends_at}, to_plan) do
    unless status == :active do
      raise InactiveSubscriptionError,
        message: "Subscription #{sub_id} is #{status} and cannot be changed",
        subscription_id: sub_id,
        status: status
    end

    if current_plan == to_plan do
      raise SameplanError,
        message: "Already subscribed to the '#{to_plan}' plan",
        plan: to_plan
    end

    current_rank = Map.get(@plan_rank, current_plan, -1)
    requested_rank = Map.get(@plan_rank, to_plan, -1)

    if requested_rank < current_rank do
      raise DowngradeNotAllowedError,
        message:
          "Downgrading from '#{current_plan}' to '#{to_plan}' is not permitted mid-cycle. " <>
            "Please cancel and re-subscribe at the end of your billing period.",
        current_plan: current_plan,
        requested_plan: to_plan
    end

    allowed = Map.get(@allowed_transitions, current_plan, [])

    unless to_plan in allowed do
      raise UnsupportedTransitionError,
        message:
          "Transition from '#{current_plan}' to '#{to_plan}' is not a supported upgrade path",
        from_plan: current_plan,
        to_plan: to_plan
    end

    days_left = DateTime.diff(cycle_ends_at, DateTime.utc_now(), :second) |> div(86_400)

    if days_left < 2 do
      raise MidCycleLockError,
        message:
          "Plan changes are locked within 2 days of cycle end. Cycle ends #{cycle_ends_at}.",
        subscription_id: sub_id,
        cycle_ends_at: cycle_ends_at
    end

    proration_cents = calculate_proration(current_plan, to_plan, days_left)

    %{
      subscription_id: sub_id,
      from_plan: current_plan,
      to_plan: to_plan,
      proration_cents: proration_cents,
      effective_at: DateTime.utc_now(),
      new_cycle_ends_at: cycle_ends_at
    }
  end

  defp calculate_proration(:starter, :pro, days_left) do
    daily_difference = trunc((4900 - 1900) / 30)
    daily_difference * days_left
  end

  defp calculate_proration(_from, _to, _days), do: 0
end

defmodule SubscriptionService do
  @moduledoc """
  Orchestrates subscription plan changes, prorations, and notifications.
  """

  require Logger

  def upgrade(subscription, to_plan_str) do
    to_plan = String.to_existing_atom(to_plan_str)

    Logger.info(
      "Plan change requested for sub #{subscription.id}: #{subscription.plan} → #{to_plan}"
    )

    # cancelled subscription, or requesting the same plan they already have,
    # are mundane UI-level events. The service is forced into try...rescue
    # because PlanUpgradePolicy.evaluate/2 does not provide a tuple-based
    # success/failure response.
    try do
      approval = PlanUpgradePolicy.evaluate(subscription, to_plan)

      Logger.info(
        "Upgrade approved for #{subscription.id}: proration #{approval.proration_cents}¢"
      )

      {:ok, approval}
    rescue
      e in PlanUpgradePolicy.DowngradeNotAllowedError ->
        Logger.info(
          "Downgrade denied for #{subscription.id}: #{e.current_plan} → #{e.requested_plan}"
        )
        {:error, :downgrade_not_allowed}

      e in PlanUpgradePolicy.MidCycleLockError ->
        Logger.info("Mid-cycle lock for #{e.subscription_id}, cycle ends #{e.cycle_ends_at}")
        {:error, {:mid_cycle_locked, e.cycle_ends_at}}

      e in PlanUpgradePolicy.UnsupportedTransitionError ->
        Logger.warning("Unsupported transition #{e.from_plan} → #{e.to_plan}")
        {:error, :unsupported_transition}

      e in PlanUpgradePolicy.SameplanError ->
        Logger.debug("No-op upgrade: already on #{e.plan}")
        {:error, :already_on_plan}

      e in PlanUpgradePolicy.InactiveSubscriptionError ->
        Logger.warning("Plan change on inactive sub #{e.subscription_id}: #{e.status}")
        {:error, {:inactive, e.status}}

      _e in ArgumentError ->
        Logger.warning("Unknown plan identifier: #{to_plan_str}")
        {:error, :unknown_plan}
    end
  end
end
```
