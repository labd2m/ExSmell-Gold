# Annotated Example 34 — Modules with Identical Names

## Metadata

- **Smell name:** Modules with identical names
- **Expected smell location:** Both `defmodule Subscriptions.PlanManager` declarations
- **Affected functions:** `Subscriptions.PlanManager.subscribe/3`, `Subscriptions.PlanManager.upgrade/3`, `Subscriptions.PlanManager.downgrade/3`, `Subscriptions.PlanManager.cancel/2`, `Subscriptions.PlanManager.renew/1`
- **Short explanation:** Two separate source files both declare `defmodule Subscriptions.PlanManager`. Because BEAM can only hold one module definition per name at a time, the second file's definition silently replaces the first, making subscription lifecycle functions permanently unreachable and breaking billing workflows for customers.

---

```elixir
# ── file: lib/subscriptions/plan_manager.ex ─────────────────────────────────

# VALIDATION: SMELL START - Modules with identical names
# VALIDATION: This is a smell because `Subscriptions.PlanManager` is declared
# here and also in a second block below. BEAM retains only the last-loaded
# definition, silently losing all functions from the discarded version.

defmodule Subscriptions.PlanManager do
  @moduledoc """
  Manages subscription plan lifecycle: subscribe, upgrade, downgrade, and cancel.
  Defined in `lib/subscriptions/plan_manager.ex`.
  """

  alias Subscriptions.{SubscriptionStore, PlanCatalog, BillingBridge, ProrationEngine}

  @cancellation_grace_days 3

  @type subscription_id :: String.t()
  @type plan_id :: String.t()
  @type account_id :: String.t()

  @type subscription :: %{
    id: subscription_id(),
    account_id: account_id(),
    plan_id: plan_id(),
    status: :active | :cancelled | :past_due | :trialing,
    current_period_start: Date.t(),
    current_period_end: Date.t(),
    cancel_at_period_end: boolean(),
    payment_method_id: String.t()
  }

  @doc """
  Subscribe an account to a plan. Creates a billing record and a subscription.
  Returns `{:ok, subscription}` or `{:error, reason}`.
  """
  @spec subscribe(account_id(), plan_id(), String.t()) ::
          {:ok, subscription()} | {:error, String.t()}
  def subscribe(account_id, plan_id, payment_method_id) do
    with {:ok, plan} <- PlanCatalog.fetch(plan_id),
         :ok <- check_no_active_subscription(account_id),
         {:ok, billing_ref} <-
           BillingBridge.create_subscription(payment_method_id, plan.stripe_price_id) do
      now = Date.utc_today()

      sub = %{
        id: generate_id(),
        account_id: account_id,
        plan_id: plan_id,
        status: :active,
        current_period_start: now,
        current_period_end: Date.add(now, plan.billing_interval_days),
        cancel_at_period_end: false,
        payment_method_id: payment_method_id,
        billing_ref: billing_ref
      }

      SubscriptionStore.save(sub)
    end
  end

  @doc "Upgrade an existing subscription to a higher-tier plan."
  @spec upgrade(subscription_id(), plan_id(), keyword()) ::
          {:ok, subscription()} | {:error, String.t()}
  def upgrade(subscription_id, new_plan_id, opts \\ []) do
    with {:ok, sub} <- SubscriptionStore.fetch(subscription_id),
         :ok <- check_active(sub),
         {:ok, new_plan} <- PlanCatalog.fetch(new_plan_id),
         {:ok, credit} <- ProrationEngine.calculate_credit(sub) do
      prorate = Keyword.get(opts, :prorate, true)

      billing_opts = if prorate, do: [credit_cents: credit], else: []

      with {:ok, _} <-
             BillingBridge.update_subscription(sub.billing_ref, new_plan.stripe_price_id, billing_opts) do
        updated = %{sub | plan_id: new_plan_id}
        SubscriptionStore.save(updated)
      end
    end
  end

  @doc "Downgrade to a lower-tier plan, effective at next billing cycle."
  @spec downgrade(subscription_id(), plan_id(), keyword()) ::
          {:ok, subscription()} | {:error, String.t()}
  def downgrade(subscription_id, new_plan_id, opts \\ []) do
    with {:ok, sub} <- SubscriptionStore.fetch(subscription_id),
         :ok <- check_active(sub) do
      effective = Keyword.get(opts, :effective, :next_cycle)

      if effective == :immediate do
        BillingBridge.update_subscription(sub.billing_ref, new_plan_id, [])
        updated = %{sub | plan_id: new_plan_id}
        SubscriptionStore.save(updated)
      else
        BillingBridge.schedule_plan_change(sub.billing_ref, new_plan_id, sub.current_period_end)
        {:ok, sub}
      end
    end
  end

  @doc "Cancel a subscription, optionally at period end."
  @spec cancel(subscription_id(), keyword()) ::
          {:ok, subscription()} | {:error, String.t()}
  def cancel(subscription_id, opts \\ []) do
    at_period_end = Keyword.get(opts, :at_period_end, true)
    reason = Keyword.get(opts, :reason, "customer_request")

    with {:ok, sub} <- SubscriptionStore.fetch(subscription_id),
         :ok <- check_active(sub) do
      if at_period_end do
        BillingBridge.cancel_at_period_end(sub.billing_ref)
        updated = %{sub | cancel_at_period_end: true}
        SubscriptionStore.save(updated)
      else
        BillingBridge.cancel_immediately(sub.billing_ref)
        updated = %{sub | status: :cancelled, cancel_reason: reason}
        SubscriptionStore.save(updated)
      end
    end
  end

  @doc "Renew an expired or past-due subscription for another billing cycle."
  @spec renew(subscription_id()) :: {:ok, subscription()} | {:error, String.t()}
  def renew(subscription_id) do
    with {:ok, sub} <- SubscriptionStore.fetch(subscription_id),
         :ok <- check_renewable(sub),
         {:ok, _charge} <- BillingBridge.charge_renewal(sub.billing_ref) do
      updated = %{
        sub
        | status: :active,
          current_period_start: sub.current_period_end,
          current_period_end: Date.add(sub.current_period_end, 30),
          cancel_at_period_end: false
      }

      SubscriptionStore.save(updated)
    end
  end

  defp check_no_active_subscription(account_id) do
    case SubscriptionStore.find_active(account_id) do
      nil -> :ok
      _ -> {:error, "Account already has an active subscription"}
    end
  end

  defp check_active(%{status: :active}), do: :ok
  defp check_active(%{status: s}), do: {:error, "Subscription is not active (status: #{s})"}

  defp check_renewable(%{status: s}) when s in [:past_due, :cancelled], do: :ok
  defp check_renewable(%{status: s}), do: {:error, "Cannot renew subscription in status: #{s}"}

  defp generate_id do
    :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
  end
end

# VALIDATION: SMELL END

# ── file: lib/subscriptions/plan_manager_trial.ex  (trial logic added later;
#    developer accidentally reused the module name) ──────────────────────────

# VALIDATION: SMELL START - Modules with identical names
# VALIDATION: This second `defmodule Subscriptions.PlanManager` replaces the
# first. `subscribe/3`, `upgrade/3`, `downgrade/3`, `cancel/2`, and `renew/1`
# from the first block all become permanently unreachable after this file loads.

defmodule Subscriptions.PlanManager do
  @moduledoc """
  Trial period management for subscriptions.
  Was intended to be `Subscriptions.PlanManager.Trial` but was accidentally
  named identically to the core plan manager.
  """

  alias Subscriptions.{SubscriptionStore, BillingBridge}

  @trial_days 14

  @doc "Start a free trial for an account on a given plan."
  @spec start_trial(String.t(), String.t()) :: {:ok, map()} | {:error, String.t()}
  def start_trial(account_id, plan_id) do
    now = Date.utc_today()

    trial = %{
      id: generate_id(),
      account_id: account_id,
      plan_id: plan_id,
      status: :trialing,
      trial_start: now,
      trial_end: Date.add(now, @trial_days),
      cancel_at_period_end: false,
      payment_method_id: nil
    }

    SubscriptionStore.save(trial)
  end

  @doc "Convert a trial subscription to a paid subscription."
  @spec convert_trial(String.t(), String.t()) :: {:ok, map()} | {:error, String.t()}
  def convert_trial(subscription_id, payment_method_id) do
    with {:ok, trial} <- SubscriptionStore.fetch(subscription_id),
         :ok <- check_trialing(trial),
         {:ok, billing_ref} <-
           BillingBridge.create_subscription(payment_method_id, trial.plan_id) do
      updated = %{
        trial
        | status: :active,
          payment_method_id: payment_method_id,
          billing_ref: billing_ref,
          current_period_start: Date.utc_today(),
          current_period_end: Date.add(Date.utc_today(), 30)
      }

      SubscriptionStore.save(updated)
    end
  end

  @doc "Expire all trials that have passed their trial_end date."
  @spec expire_trials() :: {:ok, non_neg_integer()}
  def expire_trials do
    today = Date.utc_today()

    expired =
      SubscriptionStore.all(status: :trialing)
      |> Enum.filter(&(Date.compare(&1.trial_end, today) == :lt))

    Enum.each(expired, fn sub ->
      SubscriptionStore.update(sub.id, %{status: :cancelled, cancel_reason: "trial_expired"})
    end)

    {:ok, length(expired)}
  end

  defp check_trialing(%{status: :trialing}), do: :ok
  defp check_trialing(%{status: s}), do: {:error, "Not a trial subscription (status: #{s})"}

  defp generate_id do
    :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
  end
end

# VALIDATION: SMELL END
```
