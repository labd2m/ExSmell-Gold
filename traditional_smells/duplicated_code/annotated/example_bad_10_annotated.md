# Annotated Example – Duplicated Code

| Field | Value |
|---|---|
| **Smell name** | Duplicated Code |
| **Expected smell location** | `Subscriptions.PlanManager.upgrade/2` and `Subscriptions.PlanManager.downgrade/2` |
| **Affected functions** | `upgrade/2`, `downgrade/2` |
| **Short explanation** | Both functions duplicate the logic that verifies the target plan is a valid, published plan and that the subscription is in a state that allows plan changes. If validity conditions change (e.g., new plan statuses are introduced), the change must be applied in two separate code blocks. |

```elixir
defmodule Subscriptions.PlanManager do
  @moduledoc """
  Manages subscription plan changes for customers, including upgrades,
  downgrades, and cancellations. Enforces business rules around valid
  plan transitions and subscription states.
  """

  alias Subscriptions.Repo
  alias Subscriptions.Plan
  alias Subscriptions.Subscription
  alias Subscriptions.BillingCycle

  @changeable_statuses [:active, :trialing]

  @doc """
  Upgrades a subscription to a higher-tier plan.
  Prorates any billing difference for the current cycle.
  """
  def upgrade(%Subscription{} = sub, target_plan_id) do
    # VALIDATION: SMELL START - Duplicated Code
    # VALIDATION: This is a smell because the two-step guard (fetch the plan,
    # check its status is :published, check subscription status is changeable)
    # is duplicated word-for-word in downgrade/2. Adding a new valid subscription
    # state or a new plan status check requires updating both functions.
    with {:ok, plan} <- fetch_published_plan(target_plan_id),
         :ok <- ensure_changeable(sub) do
      {:ok, {plan, sub}}
    end
    # VALIDATION: SMELL END
    |> case do
      {:ok, {plan, sub}} ->
        proration = BillingCycle.prorate(sub, plan)
        updated_sub = %{sub | plan_id: plan.id, plan_change_at: DateTime.utc_now()}
        Repo.update(updated_sub)
        {:ok, %{subscription: updated_sub, proration_credit: proration}}

      {:error, _} = error ->
        error
    end
  end

  @doc """
  Downgrades a subscription to a lower-tier plan.
  The change takes effect at the next billing cycle.
  """
  def downgrade(%Subscription{} = sub, target_plan_id) do
    # VALIDATION: SMELL START - Duplicated Code
    # VALIDATION: This is a smell because this with block is an identical copy
    # of the validation logic used in upgrade/2.
    with {:ok, plan} <- fetch_published_plan(target_plan_id),
         :ok <- ensure_changeable(sub) do
      {:ok, {plan, sub}}
    end
    # VALIDATION: SMELL END
    |> case do
      {:ok, {plan, sub}} ->
        scheduled_at = BillingCycle.next_renewal_date(sub)
        updated_sub = %{sub | pending_plan_id: plan.id, pending_plan_change_at: scheduled_at}
        Repo.update(updated_sub)
        {:ok, %{subscription: updated_sub, effective_date: scheduled_at}}

      {:error, _} = error ->
        error
    end
  end

  @doc """
  Immediately cancels a subscription. No proration is applied.
  """
  def cancel(%Subscription{} = sub, reason \\ :user_requested) do
    if sub.status not in @changeable_statuses do
      {:error, :subscription_not_active}
    else
      updated = %{sub | status: :cancelled, cancelled_at: DateTime.utc_now(), cancel_reason: reason}
      Repo.update(updated)
    end
  end

  @doc """
  Returns a list of plans the given subscription can transition to.
  """
  def available_transitions(%Subscription{} = sub) do
    current = Repo.get!(Plan, sub.plan_id)

    Repo.all_by(Plan, status: :published)
    |> Enum.reject(&(&1.id == current.id))
    |> Enum.map(fn plan ->
      %{
        plan_id: plan.id,
        name: plan.name,
        direction: if(plan.price_cents > current.price_cents, do: :upgrade, else: :downgrade)
      }
    end)
  end

  defp fetch_published_plan(plan_id) do
    case Repo.get(Plan, plan_id) do
      nil -> {:error, :plan_not_found}
      %Plan{status: :published} = plan -> {:ok, plan}
      _ -> {:error, :plan_not_available}
    end
  end

  defp ensure_changeable(%Subscription{status: status}) do
    if status in @changeable_statuses, do: :ok, else: {:error, :subscription_not_changeable}
  end
end
```
