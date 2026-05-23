```elixir
defmodule SubscriptionGate do
  @moduledoc """
  Controls access to premium features based on the tenant's active subscription plan.
  """

  alias Subscriptions.{Subscription, Plan, FeatureFlag, UsageTracker, EventBus}

  @active_statuses [:active, :trialing]
  @grace_period_hours 48

  def enforce_api_access(tenant_id, request_meta) do
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
    else
      false -> {:error, :feature_not_available}
      {:error, :not_found} -> {:error, :no_active_subscription}
      error -> error
    end
  end

  def enforce_export_access(tenant_id, export_params) do
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
