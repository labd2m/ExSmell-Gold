# Annotated Example — Duplicated Code

## Metadata

- **Smell name:** Duplicated Code
- **Expected smell location:** `SubscriptionGate.enforce_api_access/2` and `SubscriptionGate.enforce_export_access/2`
- **Affected functions:** `enforce_api_access/2`, `enforce_export_access/2`
- **Short explanation:** Both enforcement functions retrieve the subscription, check its status, verify it has not passed the billing period end, and look up the plan's feature flags. This subscription-and-plan resolution block is duplicated in each function.

---

```elixir
defmodule SubscriptionGate do
  @moduledoc """
  Controls access to premium features based on the tenant's active subscription plan.
  """

  alias Subscriptions.{Subscription, Plan, FeatureFlag, UsageTracker, EventBus}

  @active_statuses [:active, :trialing]
  @grace_period_hours 48

  def enforce_api_access(tenant_id, request_meta) do
    # VALIDATION: SMELL START - Duplicated Code
    # VALIDATION: This is a smell because the subscription fetch, status check,
    # grace-period window calculation, and plan feature-flag lookup below are
    # reproduced identically in `enforce_export_access/2`.
    with {:ok, sub} <- Subscription.fetch_active(tenant_id),
         true <- sub.status in @active_statuses or within_grace_period?(sub),
         {:ok, plan} <- Plan.fetch(sub.plan_id),
         true <- FeatureFlag.enabled?(plan, :api_access) do

      daily_limit = plan.limits[:api_calls_per_day] || 1_000
      current_usage = UsageTracker.today_count(tenant_id, :api_calls)

      if current_usage >= daily_limit do
        {:error, :rate_limit_exceeded}
      else
        UsageTracker.increment(tenant_id, :api_calls)
        {:ok, %{tenant_id: tenant_id, remaining: daily_limit - current_usage - 1}}
      end
    # VALIDATION: SMELL END
    else
      false -> {:error, :feature_not_available}
      {:error, :not_found} -> {:error, :no_active_subscription}
      error -> error
    end
  end

  def enforce_export_access(tenant_id, export_params) do
    # VALIDATION: SMELL START - Duplicated Code
    # VALIDATION: This is a smell because the subscription retrieval, status
    # validation, grace-period check, and feature-flag resolution here duplicate
    # the block in `enforce_api_access/2`. A change to grace period logic or how
    # feature flags are looked up must be applied in both functions.
    with {:ok, sub} <- Subscription.fetch_active(tenant_id),
         true <- sub.status in @active_statuses or within_grace_period?(sub),
         {:ok, plan} <- Plan.fetch(sub.plan_id),
         true <- FeatureFlag.enabled?(plan, :data_export) do

      max_rows = plan.limits[:export_max_rows] || 10_000

      if export_params.estimated_rows > max_rows do
        {:error, {:export_too_large, max_rows}}
      else
        job = %{
          tenant_id: tenant_id,
          format: export_params.format,
          filters: export_params.filters,
          max_rows: max_rows,
          requested_at: DateTime.utc_now()
        }

        EventBus.publish(:export_requested, job)
        {:ok, job}
      end
    # VALIDATION: SMELL END
    else
      false -> {:error, :feature_not_available}
      {:error, :not_found} -> {:error, :no_active_subscription}
      error -> error
    end
  end

  def enforce_sso_access(tenant_id) do
    with {:ok, sub} <- Subscription.fetch_active(tenant_id),
         true <- sub.status in @active_statuses,
         {:ok, plan} <- Plan.fetch(sub.plan_id),
         true <- FeatureFlag.enabled?(plan, :sso) do
      {:ok, :sso_allowed}
    else
      false -> {:error, :feature_not_available}
      error -> error
    end
  end

  def current_plan(tenant_id) do
    with {:ok, sub} <- Subscription.fetch_active(tenant_id),
         {:ok, plan} <- Plan.fetch(sub.plan_id) do
      {:ok,
       %{
         plan_name: plan.name,
         status: sub.status,
         current_period_end: sub.current_period_end,
         features: plan.features,
         limits: plan.limits
       }}
    end
  end

  defp within_grace_period?(%{current_period_end: nil}), do: false

  defp within_grace_period?(%{current_period_end: period_end}) do
    grace_cutoff = DateTime.add(period_end, @grace_period_hours * 3_600, :second)
    DateTime.compare(DateTime.utc_now(), grace_cutoff) == :lt
  end
end
```
