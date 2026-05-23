# Example Bad 08 — Annotated

## Metadata

- **Smell Name**: Shotgun Surgery
- **Expected Smell Location**: Functions `get_storage_quota_mb/1`, `get_monthly_api_limit/1`, `get_support_level/1`, and `calculate_monthly_cost/1` inside `Accounts.TierManager`
- **Affected Functions**: `get_storage_quota_mb/1`, `get_monthly_api_limit/1`, `get_support_level/1`, `calculate_monthly_cost/1`
- **Explanation**: The account tier logic (`:free`, `:starter`, `:premium`) is distributed across four separate functions. Adding a new tier (e.g., `:enterprise`) forces four independent edits scattered across the module, embodying Shotgun Surgery.

```elixir
defmodule Accounts.TierManager do
  @moduledoc """
  Manages user account tiers including storage quotas, API rate limits,
  support level entitlements, and billing cost calculation.
  Tier changes trigger downstream updates across the platform.
  """

  alias Accounts.{Account, UsageTracker, BillingScheduler, SupportRouter, FeatureFlags}

  def upgrade_tier(%Account{} = account, new_tier) do
    with :ok <- validate_tier_transition(account.tier, new_tier),
         :ok <- check_payment_method(account),
         {:ok, updated} <- apply_tier_change(account, new_tier),
         :ok <- BillingScheduler.update_subscription(updated) do
      SupportRouter.reassign(updated.id, get_support_level(new_tier))
      FeatureFlags.sync(updated.id, new_tier)
      {:ok, updated}
    end
  end

  def downgrade_tier(%Account{} = account, new_tier) do
    with :ok <- validate_tier_transition(account.tier, new_tier),
         {:ok, updated} <- apply_tier_change(account, new_tier) do
      UsageTracker.enforce_quota(updated.id, get_storage_quota_mb(new_tier))
      BillingScheduler.update_subscription(updated)
      SupportRouter.reassign(updated.id, get_support_level(new_tier))
      {:ok, updated}
    end
  end

  defp apply_tier_change(account, new_tier) do
    updated = %{account |
      tier:              new_tier,
      storage_quota_mb:  get_storage_quota_mb(new_tier),
      api_limit:         get_monthly_api_limit(new_tier),
      support_level:     get_support_level(new_tier),
      monthly_cost:      calculate_monthly_cost(new_tier),
      tier_changed_at:   DateTime.utc_now()
    }

    Accounts.Repo.update(updated)
  end

  defp validate_tier_transition(:free, :starter),     do: :ok
  defp validate_tier_transition(:free, :premium),     do: :ok
  defp validate_tier_transition(:starter, :premium),  do: :ok
  defp validate_tier_transition(:premium, :starter),  do: :ok
  defp validate_tier_transition(:starter, :free),     do: :ok
  defp validate_tier_transition(from, to) when from == to, do: {:error, :same_tier}
  defp validate_tier_transition(_, _),                do: {:error, :invalid_transition}

  defp check_payment_method(%Account{payment_method: nil}),
    do: {:error, :payment_method_required}
  defp check_payment_method(_), do: :ok

  # VALIDATION: SMELL START - Shotgun Surgery [location 1 of 4]
  # VALIDATION: This is a smell because adding a new tier (e.g., :enterprise)
  # requires a new clause here AND in get_monthly_api_limit/1, get_support_level/1,
  # and calculate_monthly_cost/1 — four scattered changes for one new tier.
  def get_storage_quota_mb(:free),    do: 500
  def get_storage_quota_mb(:starter), do: 10_000
  def get_storage_quota_mb(:premium), do: 100_000
  def get_storage_quota_mb(_),        do: 100
  # VALIDATION: SMELL END [location 1 of 4]

  # VALIDATION: SMELL START - Shotgun Surgery [location 2 of 4]
  # VALIDATION: This is a smell because a new tier requires a new API limit clause here,
  # independent of the change already needed in get_storage_quota_mb/1.
  def get_monthly_api_limit(:free),    do: 1_000
  def get_monthly_api_limit(:starter), do: 50_000
  def get_monthly_api_limit(:premium), do: 500_000
  def get_monthly_api_limit(_),        do: 100
  # VALIDATION: SMELL END [location 2 of 4]

  # VALIDATION: SMELL START - Shotgun Surgery [location 3 of 4]
  # VALIDATION: This is a smell because a new tier also requires a new support level
  # clause here, independent of the changes in the previous two locations.
  def get_support_level(:free),    do: :community
  def get_support_level(:starter), do: :email
  def get_support_level(:premium), do: :priority
  def get_support_level(_),        do: :none
  # VALIDATION: SMELL END [location 3 of 4]

  # VALIDATION: SMELL START - Shotgun Surgery [location 4 of 4]
  # VALIDATION: This is a smell because a new tier also requires a monthly cost clause here,
  # completing the four-location change for every new tier type.
  def calculate_monthly_cost(:free),    do: 0.00
  def calculate_monthly_cost(:starter), do: 9.99
  def calculate_monthly_cost(:premium), do: 29.99
  def calculate_monthly_cost(_),        do: 0.00
  # VALIDATION: SMELL END [location 4 of 4]

  def get_current_usage(%Account{id: account_id} = account) do
    usage = UsageTracker.get(account_id)
    quota = get_storage_quota_mb(account.tier)
    limit = get_monthly_api_limit(account.tier)

    %{
      storage_used_mb:    usage.storage_mb,
      storage_quota_mb:   quota,
      storage_pct:        Float.round(usage.storage_mb / quota * 100, 1),
      api_calls_used:     usage.api_calls,
      api_limit:          limit,
      api_pct:            Float.round(usage.api_calls / limit * 100, 1)
    }
  end

  def list_tiers do
    [:free, :starter, :premium]
  end
end
```
