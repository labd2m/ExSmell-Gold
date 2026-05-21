```elixir
defmodule SubscriptionCharger do
  @moduledoc """
  Attempts to collect a recurring subscription payment for a due billing period.
  Enforces subscription state, grace period, and payment method checks.
  """

  defmodule SubscriptionCancelledError do
    defexception [:message, :subscription_id, :cancelled_at]
  end

  defmodule GracePeriodExpiredError do
    defexception [:message, :subscription_id, :grace_expired_at]
  end

  defmodule MissingPaymentMethodError do
    defexception [:message, :account_id]
  end

  defmodule CardDeclinedError do
    defexception [:message, :subscription_id, :decline_code]
  end

  defmodule SubscriptionNotFoundError do
    defexception [:message, :subscription_id]
  end

  @grace_period_days 7

  @subscriptions %{
    "sub-001" => %{
      id: "sub-001",
      account_id: "acc-001",
      plan: :pro,
      status: :active,
      amount_cents: 4900,
      currency: "USD",
      cancelled_at: nil,
      past_due_since: nil
    },
    "sub-002" => %{
      id: "sub-002",
      account_id: "acc-002",
      plan: :starter,
      status: :cancelled,
      amount_cents: 1900,
      currency: "USD",
      cancelled_at: ~U[2025-08-01 00:00:00Z],
      past_due_since: nil
    },
    "sub-003" => %{
      id: "sub-003",
      account_id: "acc-003",
      plan: :pro,
      status: :past_due,
      amount_cents: 4900,
      currency: "USD",
      cancelled_at: nil,
      past_due_since: ~U[2025-08-25 00:00:00Z]
    }
  }

  @payment_methods %{
    "acc-001" => %{type: :card, last4: "4242", brand: :visa}
  }

  def charge_due(subscription_id) do
    sub = Map.get(@subscriptions, subscription_id)

    if is_nil(sub) do
      raise SubscriptionNotFoundError,
        message: "Subscription '#{subscription_id}' not found",
        subscription_id: subscription_id
    end

    if sub.status == :cancelled do
      raise SubscriptionCancelledError,
        message: "Subscription '#{subscription_id}' was cancelled on #{sub.cancelled_at}",
        subscription_id: subscription_id,
        cancelled_at: sub.cancelled_at
    end

    if sub.status == :past_due and not is_nil(sub.past_due_since) do
      days_past_due = DateTime.diff(DateTime.utc_now(), sub.past_due_since, :second) |> div(86_400)

      if days_past_due > @grace_period_days do
        expired_at = DateTime.add(sub.past_due_since, @grace_period_days * 86_400, :second)

        raise GracePeriodExpiredError,
          message:
            "Grace period for subscription '#{subscription_id}' expired at #{expired_at}",
          subscription_id: subscription_id,
          grace_expired_at: expired_at
      end
    end

    pm = Map.get(@payment_methods, sub.account_id)

    if is_nil(pm) do
      raise MissingPaymentMethodError,
        message: "No payment method on file for account '#{sub.account_id}'",
        account_id: sub.account_id
    end

    case simulate_charge(sub.account_id, sub.amount_cents) do
      {:ok, charge_id} ->
        %{
          charge_id: charge_id,
          subscription_id: subscription_id,
          account_id: sub.account_id,
          amount_cents: sub.amount_cents,
          currency: sub.currency,
          charged_at: DateTime.utc_now()
        }

      {:declined, code} ->
        raise CardDeclinedError,
          message: "Card declined for subscription #{subscription_id}: #{code}",
          subscription_id: subscription_id,
          decline_code: code
    end
  end

  defp simulate_charge(_account_id, _amount), do: {:ok, "ch_#{System.unique_integer([:positive])}"}
end

defmodule RecurringBillingJob do
  @moduledoc """
  Scheduled job that processes all subscriptions due for renewal.
  """

  require Logger

  def run(subscription_ids) do
    Logger.info("Starting recurring billing run for #{length(subscription_ids)} subscriptions")

    results =
      Enum.map(subscription_ids, fn sub_id ->
        # subscriptions will be cancelled, past due, or have no payment
        # method — these are expected states, not errors. The job is forced
        # to use try...rescue for routine billing classification because
        # SubscriptionCharger offers no tuple-returning version.
        result =
          try do
            charge = SubscriptionCharger.charge_due(sub_id)
            Logger.info("Charged #{sub_id}: #{charge.charge_id}")
            {:ok, charge}
          rescue
            e in SubscriptionCharger.SubscriptionCancelledError ->
              Logger.debug("Skipping cancelled subscription #{e.subscription_id}")
              {:skip, :cancelled}

            e in SubscriptionCharger.GracePeriodExpiredError ->
              Logger.warning("Grace expired for #{e.subscription_id} at #{e.grace_expired_at}")
              {:action_required, :suspend_account}

            e in SubscriptionCharger.MissingPaymentMethodError ->
              Logger.warning("No payment method for account #{e.account_id}")
              {:action_required, :request_payment_method}

            e in SubscriptionCharger.CardDeclinedError ->
              Logger.warning("Card declined for #{e.subscription_id}: #{e.decline_code}")
              {:retry, e.decline_code}

            e in SubscriptionCharger.SubscriptionNotFoundError ->
              Logger.error("Subscription not found: #{e.subscription_id}")
              {:error, :not_found}
          end

        {sub_id, result}
      end)

    summarise(results)
  end

  defp summarise(results) do
    grouped = Enum.group_by(results, fn {_, {status, _}} -> status end)
    Logger.info("Billing run complete: #{inspect(Map.keys(grouped) |> Enum.frequencies())}")
    results
  end
end
```
