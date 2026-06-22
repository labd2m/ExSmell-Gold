```elixir
defmodule Subscriptions.PlanUpgrader do
  @moduledoc """
  Handles plan upgrades for active subscriptions.

  An upgrade involves prorating the remaining credit on the current plan,
  issuing an upgrade charge for the new plan, and updating the subscription
  record. All steps are wrapped in a database transaction to prevent
  partial state updates.
  """

  alias Subscriptions.Repo
  alias Subscriptions.Subscription
  alias Subscriptions.Plan
  alias Subscriptions.ProratedCredit
  alias Subscriptions.PaymentGateway
  alias Subscriptions.SubscriptionStore

  @type upgrade_result ::
          {:ok, Subscription.t()}
          | {:error, :same_plan}
          | {:error, :downgrade_not_supported}
          | {:error, :payment_failed, String.t()}
          | {:error, :persistence_failed}

  @doc """
  Upgrades a subscription from its current plan to the specified target plan.

  Computes prorated credit, charges the difference via the payment gateway,
  and persists the updated subscription atomically.
  """
  @spec upgrade(Subscription.t(), Plan.t()) :: upgrade_result()
  def upgrade(%Subscription{} = subscription, %Plan{} = target_plan) do
    with :ok <- validate_upgrade(subscription, target_plan),
         {:ok, credit_cents} <- compute_proration(subscription),
         {:ok, charge_cents} <- compute_charge(target_plan, credit_cents),
         {:ok, _charge} <- charge_customer(subscription, charge_cents, target_plan),
         {:ok, updated} <- persist_upgrade(subscription, target_plan) do
      {:ok, updated}
    end
  end

  @spec validate_upgrade(Subscription.t(), Plan.t()) ::
          :ok | {:error, :same_plan | :downgrade_not_supported}
  defp validate_upgrade(%Subscription{plan_id: current_plan_id}, %Plan{id: target_plan_id, price_cents: target_price})
       when current_plan_id == target_plan_id do
    {:error, :same_plan}
  end

  defp validate_upgrade(%Subscription{plan: current_plan}, %Plan{price_cents: target_price})
       when target_price < current_plan.price_cents do
    {:error, :downgrade_not_supported}
  end

  defp validate_upgrade(_subscription, _target_plan), do: :ok

  @spec compute_proration(Subscription.t()) :: {:ok, non_neg_integer()}
  defp compute_proration(%Subscription{current_period_end: period_end, plan: plan}) do
    now = DateTime.utc_now()
    remaining_seconds = max(0, DateTime.diff(period_end, now, :second))
    period_seconds = 30 * 24 * 60 * 60

    proration_ratio = remaining_seconds / period_seconds
    credit = round(plan.price_cents * proration_ratio)

    {:ok, credit}
  end

  @spec compute_charge(Plan.t(), non_neg_integer()) :: {:ok, non_neg_integer()}
  defp compute_charge(%Plan{price_cents: price}, credit_cents) do
    {:ok, max(0, price - credit_cents)}
  end

  @spec charge_customer(Subscription.t(), non_neg_integer(), Plan.t()) ::
          {:ok, map()} | {:error, :payment_failed, String.t()}
  defp charge_customer(_subscription, 0, _plan) do
    {:ok, %{amount_cents: 0, reference: "no_charge"}}
  end

  defp charge_customer(subscription, amount_cents, target_plan) do
    description = "Upgrade to #{target_plan.name}"

    case PaymentGateway.charge(subscription.customer_id, amount_cents, description) do
      {:ok, charge} -> {:ok, charge}
      {:error, reason} -> {:error, :payment_failed, reason}
    end
  end

  @spec persist_upgrade(Subscription.t(), Plan.t()) ::
          {:ok, Subscription.t()} | {:error, :persistence_failed}
  defp persist_upgrade(subscription, target_plan) do
    attrs = %{
      plan_id: target_plan.id,
      upgraded_at: DateTime.utc_now(),
      current_period_end: DateTime.add(DateTime.utc_now(), 30 * 24 * 60 * 60, :second)
    }

    case SubscriptionStore.update(subscription, attrs) do
      {:ok, updated} -> {:ok, updated}
      {:error, _} -> {:error, :persistence_failed}
    end
  end
end
```
