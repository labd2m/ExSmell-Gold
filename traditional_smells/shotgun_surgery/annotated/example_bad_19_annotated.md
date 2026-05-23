# Example Bad 19 — Annotated

## Metadata

- **Smell Name**: Shotgun Surgery
- **Expected Smell Location**: Functions `get_seat_limit/1`, `get_api_quota_per_month/1`, `get_data_retention_days/1`, and `calculate_monthly_rate/2` inside `SaaS.WorkspaceManager`
- **Affected Functions**: `get_seat_limit/1`, `get_api_quota_per_month/1`, `get_data_retention_days/1`, `calculate_monthly_rate/2`
- **Explanation**: The workspace plan logic (`:starter`, `:growth`, `:enterprise`) is distributed across four separate functions. Adding a new plan (e.g., `:business`) requires four independent edits in different parts of the module, a hallmark of Shotgun Surgery.

```elixir
defmodule SaaS.WorkspaceManager do
  @moduledoc """
  Manages SaaS workspace configuration including seat limits,
  API quotas, data retention policies, and monthly billing
  calculation for different workspace plan tiers.
  """

  alias SaaS.{
    Workspace, Subscription, BillingEngine,
    QuotaEnforcer, RetentionPolicy, UsageDashboard, OnboardingFlow
  }

  def provision_workspace(owner_id, plan, seat_count, billing_cycle) do
    with :ok              <- validate_seat_count(plan, seat_count),
         {:ok, workspace} <- create_workspace(owner_id, plan, seat_count, billing_cycle),
         :ok              <- QuotaEnforcer.initialize(workspace),
         :ok              <- RetentionPolicy.apply(workspace.id, get_data_retention_days(plan)),
         :ok              <- OnboardingFlow.start(workspace) do
      {:ok, workspace}
    end
  end

  defp create_workspace(owner_id, plan, seat_count, billing_cycle) do
    monthly_rate = calculate_monthly_rate(plan, seat_count)
    total_due    = if billing_cycle == :annual, do: monthly_rate * 12 * 0.85, else: monthly_rate

    workspace = %Workspace{
      owner_id:            owner_id,
      plan:                plan,
      seat_count:          seat_count,
      seat_limit:          get_seat_limit(plan),
      api_quota:           get_api_quota_per_month(plan),
      data_retention_days: get_data_retention_days(plan),
      billing_cycle:       billing_cycle,
      monthly_rate:        monthly_rate,
      next_invoice_amount: total_due,
      next_billing_date:   next_billing_date(billing_cycle),
      status:              :active,
      created_at:          DateTime.utc_now()
    }

    Workspace.insert(workspace)
  end

  defp next_billing_date(:monthly), do: Date.add(Date.utc_today(), 30)
  defp next_billing_date(:annual),  do: Date.add(Date.utc_today(), 365)
  defp next_billing_date(_),        do: Date.add(Date.utc_today(), 30)

  defp validate_seat_count(plan, seat_count) do
    limit = get_seat_limit(plan)
    if seat_count > 0 and seat_count <= limit do
      :ok
    else
      {:error, {:seat_count_invalid, limit: limit, requested: seat_count}}
    end
  end

  def add_seat(%Workspace{} = workspace) do
    limit = get_seat_limit(workspace.plan)

    if workspace.seat_count >= limit do
      {:error, :seat_limit_reached}
    else
      new_count    = workspace.seat_count + 1
      new_rate     = calculate_monthly_rate(workspace.plan, new_count)
      updated      = %{workspace | seat_count: new_count, monthly_rate: new_rate}

      with {:ok, saved} <- Workspace.update(updated) do
        BillingEngine.prorate_seat_addition(saved)
        {:ok, saved}
      end
    end
  end

  def get_usage_summary(%Workspace{} = workspace) do
    usage = UsageDashboard.fetch(workspace.id)
    %{
      plan:              workspace.plan,
      seats_used:        workspace.seat_count,
      seats_available:   get_seat_limit(workspace.plan) - workspace.seat_count,
      api_calls_used:    usage.api_calls,
      api_quota:         get_api_quota_per_month(workspace.plan),
      api_pct:           Float.round(usage.api_calls / get_api_quota_per_month(workspace.plan) * 100, 1),
      data_retention:    get_data_retention_days(workspace.plan)
    }
  end

  # VALIDATION: SMELL START - Shotgun Surgery [location 1 of 4]
  # VALIDATION: This is a smell because adding a new plan (e.g., :business)
  # requires a new clause here AND in get_api_quota_per_month/1, get_data_retention_days/1,
  # and calculate_monthly_rate/2 — four scattered changes for one new plan.
  def get_seat_limit(:starter),    do: 5
  def get_seat_limit(:growth),     do: 25
  def get_seat_limit(:enterprise), do: 500
  def get_seat_limit(_),           do: 1
  # VALIDATION: SMELL END [location 1 of 4]

  # VALIDATION: SMELL START - Shotgun Surgery [location 2 of 4]
  # VALIDATION: This is a smell because a new plan also requires a new API quota
  # clause here, independent of get_seat_limit/1.
  def get_api_quota_per_month(:starter),    do: 10_000
  def get_api_quota_per_month(:growth),     do: 100_000
  def get_api_quota_per_month(:enterprise), do: 5_000_000
  def get_api_quota_per_month(_),           do: 1_000
  # VALIDATION: SMELL END [location 2 of 4]

  # VALIDATION: SMELL START - Shotgun Surgery [location 3 of 4]
  # VALIDATION: This is a smell because a new plan also needs a data retention clause
  # here, independent of the previous two locations.
  def get_data_retention_days(:starter),    do: 30
  def get_data_retention_days(:growth),     do: 180
  def get_data_retention_days(:enterprise), do: 2_555
  def get_data_retention_days(_),           do: 7
  # VALIDATION: SMELL END [location 3 of 4]

  # VALIDATION: SMELL START - Shotgun Surgery [location 4 of 4]
  # VALIDATION: This is a smell because a new plan also requires a rate calculation
  # clause here, completing the four-location change for every new plan.
  def calculate_monthly_rate(:starter, seat_count) do
    Float.round(19.00 * seat_count, 2)
  end

  def calculate_monthly_rate(:growth, seat_count) do
    Float.round(15.00 * seat_count, 2)
  end

  def calculate_monthly_rate(:enterprise, seat_count) do
    Float.round(12.00 * seat_count, 2)
  end

  def calculate_monthly_rate(_plan, seat_count) do
    Float.round(25.00 * seat_count, 2)
  end
  # VALIDATION: SMELL END [location 4 of 4]

  def list_plans, do: [:starter, :growth, :enterprise]
end
```
