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

      plan_id       = sub.plan_id
      cycle_ends_at = sub.cycle_ends_at
      grace_days    = sub.grace_period_days

      token        = billing.payment_method_token
      retry_count  = billing.retry_count
      max_retries  = billing.max_retries

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
