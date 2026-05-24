# Code Smell Example – Annotated

## Metadata

- **Smell name:** Inappropriate Intimacy
- **Expected smell location:** `SubscriptionRenewal.renew/1` function
- **Affected function(s):** `SubscriptionRenewal.renew/1`
- **Short explanation:** `SubscriptionRenewal.renew/1` fetches a `Subscription` struct and a `BillingProfile` struct and then directly reads internal fields (`.plan_id`, `.cycle_ends_at`, `.grace_period_days`, `.payment_method_token`, `.retry_count`, `.max_retries`) to execute the renewal. These internal policies and credentials belong in `Subscription` and `BillingProfile` and should not be exposed to this module as raw fields.

---

```elixir
defmodule MyApp.Subscriptions.SubscriptionRenewal do
  @moduledoc """
  Processes subscription renewals at the end of each billing cycle.
  Handles payment retries, grace periods, and expiration logic.
  """

  alias MyApp.Subscriptions.{Subscription, BillingProfile}
  alias MyApp.Plans.Plan
  alias MyApp.Payments.PaymentGateway
  alias MyApp.Notifications.{RenewalMailer, ExpiryMailer}

  @renewal_job_concurrency 10

  def renew(subscription_id) do
    with {:ok, sub}     <- Subscription.fetch(subscription_id),
         {:ok, billing} <- BillingProfile.for_subscription(subscription_id) do

      # VALIDATION: SMELL START - Inappropriate Intimacy
      # VALIDATION: This is a smell because renew/1 directly reads .plan_id,
      # .cycle_ends_at, and .grace_period_days from the Subscription struct, and
      # .payment_method_token, .retry_count, and .max_retries from the BillingProfile
      # struct. These fields are internal state that should be encapsulated — for example,
      # Subscription should expose whether it is within its grace period, and BillingProfile
      # should expose whether retries are exhausted.
      plan_id       = sub.plan_id
      cycle_ends_at = sub.cycle_ends_at
      grace_days    = sub.grace_period_days

      token        = billing.payment_method_token
      retry_count  = billing.retry_count
      max_retries  = billing.max_retries
      # VALIDATION: SMELL END

      {:ok, plan} = Plan.fetch(plan_id)

      now          = DateTime.utc_now()
      grace_cutoff = DateTime.add(cycle_ends_at, grace_days * 86_400, :second)

      cond do
        DateTime.compare(now, grace_cutoff) == :gt ->
          expire_subscription(sub)
          ExpiryMailer.deliver(sub)
          {:error, :subscription_expired}

        retry_count >= max_retries ->
          suspend_subscription(sub)
          {:error, :max_retries_exceeded}

        true ->
          attempt_charge(sub, billing, plan, token, retry_count)
      end
    end
  end

  def process_batch(subscription_ids) do
    subscription_ids
    |> Task.async_stream(&renew/1,
        max_concurrency: @renewal_job_concurrency,
        timeout: 15_000,
        on_timeout: :kill_task)
    |> Enum.reduce({0, 0}, fn
      {:ok, {:ok, _}},      {ok, err} -> {ok + 1, err}
      {:ok, {:error, _}},   {ok, err} -> {ok, err + 1}
      {:exit, _},           {ok, err} -> {ok, err + 1}
    end)
  end

  def cancel(subscription_id, reason \\ :user_requested) do
    case Subscription.fetch(subscription_id) do
      nil -> {:error, :not_found}
      sub ->
        updated = %{sub | status: :cancelled, cancelled_at: DateTime.utc_now(), cancel_reason: reason}
        Subscription.save(updated)
        {:ok, updated}
    end
  end

  # --- Private helpers ---

  defp attempt_charge(sub, billing, plan, token, retry_count) do
    case PaymentGateway.charge(token, plan.price, plan.currency) do
      {:ok, charge_id} ->
        next_cycle = DateTime.add(sub.cycle_ends_at, plan.cycle_days * 86_400, :second)
        updated    = %{sub | status: :active, cycle_ends_at: next_cycle}
        Subscription.save(updated)
        BillingProfile.reset_retries(billing.id)
        RenewalMailer.deliver_success(sub, charge_id)
        {:ok, updated}

      {:error, reason} ->
        BillingProfile.increment_retries(billing.id)
        RenewalMailer.deliver_failure(sub, reason)
        {:error, {:charge_failed, reason}}
    end
  end

  defp expire_subscription(sub) do
    updated = %{sub | status: :expired, expired_at: DateTime.utc_now()}
    Subscription.save(updated)
  end

  defp suspend_subscription(sub) do
    updated = %{sub | status: :suspended, suspended_at: DateTime.utc_now()}
    Subscription.save(updated)
  end
end
```
