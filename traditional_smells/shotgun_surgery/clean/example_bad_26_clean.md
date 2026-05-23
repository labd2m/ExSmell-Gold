```elixir
defmodule Billing.PlanCatalog do
  @moduledoc """
  Defines pricing, billing intervals, and trial configuration for all
  subscription plans offered on the platform.
  """


  @spec monthly_price(atom()) :: float()
  def monthly_price(:starter),      do: 29.0
  def monthly_price(:professional),  do: 99.0
  def monthly_price(:enterprise),    do: 299.0

  @spec billing_interval(atom()) :: atom()
  def billing_interval(:starter),     do: :monthly
  def billing_interval(:professional), do: :monthly
  def billing_interval(:enterprise),   do: :annual

  @spec trial_days(atom()) :: non_neg_integer()
  def trial_days(:starter),      do: 14
  def trial_days(:professional),  do: 14
  def trial_days(:enterprise),    do: 30

  @spec display_name(atom()) :: String.t()
  def display_name(:starter),      do: "Starter"
  def display_name(:professional),  do: "Professional"
  def display_name(:enterprise),    do: "Enterprise"


  def all_plans, do: [:starter, :professional, :enterprise]

  def plan_details(plan) do
    %{
      name:             display_name(plan),
      price:            monthly_price(plan),
      interval:         billing_interval(plan),
      trial_days:       trial_days(plan)
    }
  end

  def upgrade_path(:starter),      do: :professional
  def upgrade_path(:professional),  do: :enterprise
  def upgrade_path(:enterprise),    do: nil
end

defmodule Platform.FeatureGate do
  @moduledoc """
  Controls access to platform features based on an account's active
  subscription plan, enforcing seat and capability limits per tier.
  """


  @spec feature_enabled?(atom(), atom()) :: boolean()
  def feature_enabled?(:starter, :api_access),           do: false
  def feature_enabled?(:starter, :sso),                  do: false
  def feature_enabled?(:starter, :advanced_reporting),   do: false
  def feature_enabled?(:starter, _),                     do: true

  def feature_enabled?(:professional, :sso),             do: false
  def feature_enabled?(:professional, :api_access),      do: true
  def feature_enabled?(:professional, :advanced_reporting), do: true
  def feature_enabled?(:professional, _),                do: true

  def feature_enabled?(:enterprise, _),                  do: true

  @spec seat_limit(atom()) :: pos_integer() | :unlimited
  def seat_limit(:starter),      do: 5
  def seat_limit(:professional),  do: 25
  def seat_limit(:enterprise),    do: :unlimited


  def check_feature_access(account, feature) do
    if feature_enabled?(account.subscription.plan, feature) do
      :allowed
    else
      {:denied, :plan_upgrade_required}
    end
  end

  def check_seat_availability(account) do
    limit        = seat_limit(account.subscription.plan)
    current_seats = length(account.members)

    case limit do
      :unlimited -> :ok
      n when current_seats < n -> :ok
      _          -> {:error, :seat_limit_reached}
    end
  end
end

defmodule Billing.SubscriptionRenewal do
  @moduledoc """
  Handles subscription renewal billing, applying plan-specific amounts
  and managing grace periods for failed payment retries.
  """


  @spec renewal_amount(atom()) :: float()
  def renewal_amount(:starter),      do: 29.0
  def renewal_amount(:professional),  do: 99.0
  def renewal_amount(:enterprise),    do: 299.0 * 12

  @spec grace_period_days(atom()) :: non_neg_integer()
  def grace_period_days(:starter),     do: 3
  def grace_period_days(:professional), do: 7
  def grace_period_days(:enterprise),   do: 14


  def renew(subscription) do
    amount = renewal_amount(subscription.plan)
    grace  = grace_period_days(subscription.plan)

    case Payments.GatewayAdapter.charge(:stripe, subscription.customer, %{
           total_cents: round(amount * 100),
           currency:    "usd",
           id:          subscription.id
         }) do
      {:ok, txn} ->
        new_period_end =
          case Billing.PlanCatalog.billing_interval(subscription.plan) do
            :monthly -> Date.add(subscription.current_period_end, 30)
            :annual  -> Date.add(subscription.current_period_end, 365)
          end

        {:ok, %{subscription | status: :active, current_period_end: new_period_end,
                               last_transaction_id: txn.transaction_id}}

      {:error, _reason} ->
        grace_end = Date.add(Date.utc_today(), grace)
        {:retry, %{subscription | status: :past_due, grace_period_end: grace_end}}
    end
  end
end
```
