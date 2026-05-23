# Annotated Example — Long Function

## Metadata

- **Smell name:** Long Function
- **Expected smell location:** `Billing.SubscriptionRenewal.renew/1`
- **Affected function(s):** `renew/1`
- **Short explanation:** The `renew/1` function handles subscription eligibility checking, plan-based pricing retrieval, proration logic, payment charging, subscription period extension, invoice emission, and failure-state handling all in one large body. Extracting each responsibility into a dedicated function would make the code far more navigable and testable.

---

```elixir
defmodule Billing.SubscriptionRenewal do
  @moduledoc """
  Handles automatic and manual subscription renewals, applying proration
  where applicable and issuing invoices on success.
  """

  alias Billing.{Subscription, Plan, Invoice, Repo}
  alias Payments.Processor
  alias Notifications.Dispatcher
  require Logger

  @grace_period_days 3
  @proration_enabled true

  # VALIDATION: SMELL START - Long Function
  # VALIDATION: This is a smell because `renew/1` performs subscription status checks,
  # VALIDATION: plan price computation, proration calculation, payment invocation,
  # VALIDATION: subscription period update, invoice creation, and notification
  # VALIDATION: dispatching all in one function with no decomposition into helpers.
  def renew(subscription_id) do
    Logger.info("Renewing subscription=#{subscription_id}")

    case Repo.get(Subscription, subscription_id) |> Repo.preload(:plan) do
      nil ->
        {:error, :subscription_not_found}

      %Subscription{status: :cancelled} ->
        {:error, :subscription_cancelled}

      %Subscription{} = sub ->
        now = DateTime.utc_now()

        # --- Check renewal window ---
        days_until_expiry = DateTime.diff(sub.current_period_end, now, :second) |> div(86_400)

        if days_until_expiry > @grace_period_days do
          {:error, {:too_early_to_renew, days_until_expiry}}
        else
          # --- Determine charge amount ---
          plan = sub.plan
          base_amount = plan.price_cents

          # --- Proration if mid-period upgrade occurred ---
          charge_amount =
            if @proration_enabled and not is_nil(sub.upgrade_credit_cents) and sub.upgrade_credit_cents > 0 do
              credited = sub.upgrade_credit_cents
              Logger.info("Applying upgrade credit #{credited} cents to renewal #{subscription_id}")
              max(base_amount - credited, 0)
            else
              base_amount
            end

          if charge_amount == 0 do
            # Free renewal (fully covered by credit)
            new_period_start = sub.current_period_end
            new_period_end   = advance_period(new_period_start, plan.interval)

            sub
            |> Subscription.changeset(%{
              current_period_start: new_period_start,
              current_period_end: new_period_end,
              upgrade_credit_cents: 0,
              status: :active,
              renewal_count: sub.renewal_count + 1
            })
            |> Repo.update!()

            emit_renewal_invoice(sub, plan, 0)
            Logger.info("Free renewal for subscription #{subscription_id}")
            {:ok, :renewed_free}
          else
            # --- Charge customer ---
            idempotency_key = "renewal-#{subscription_id}-#{sub.current_period_end |> DateTime.to_unix()}"

            case Processor.charge_by_customer(sub.customer_id, charge_amount, idempotency_key) do
              {:ok, transaction} ->
                new_period_start = sub.current_period_end
                new_period_end   = advance_period(new_period_start, plan.interval)

                sub
                |> Subscription.changeset(%{
                  current_period_start: new_period_start,
                  current_period_end: new_period_end,
                  upgrade_credit_cents: 0,
                  status: :active,
                  last_transaction_id: transaction.id,
                  renewal_count: sub.renewal_count + 1
                })
                |> Repo.update!()

                emit_renewal_invoice(sub, plan, charge_amount)

                Dispatcher.dispatch(sub.user_id, %{
                  type: "subscription_renewed",
                  payload: %{
                    subscription_id: sub.id,
                    plan_name: plan.name,
                    amount_cents: charge_amount,
                    new_period_end: new_period_end
                  }
                })

                Logger.info("Subscription #{subscription_id} renewed, new period ends #{new_period_end}")
                {:ok, :renewed}

              {:error, {:gateway_error, code, msg}} ->
                Logger.error("Renewal payment failed for #{subscription_id}: #{code} #{msg}")

                sub
                |> Subscription.changeset(%{status: :past_due, last_payment_error: msg})
                |> Repo.update!()

                Dispatcher.dispatch(sub.user_id, %{
                  type: "payment_failed",
                  payload: %{subscription_id: sub.id, reason: msg}
                })

                {:error, {:payment_failed, code}}

              {:error, reason} ->
                Logger.error("Unexpected renewal error for #{subscription_id}: #{inspect(reason)}")
                {:error, reason}
            end
          end
        end
    end
  end
  # VALIDATION: SMELL END

  defp advance_period(from, :monthly), do: Timex.shift(from, months: 1)
  defp advance_period(from, :yearly),  do: Timex.shift(from, years: 1)
  defp advance_period(from, :weekly),  do: DateTime.add(from, 7 * 86_400, :second)

  defp emit_renewal_invoice(sub, plan, amount_cents) do
    Repo.insert!(%Invoice{
      subscription_id: sub.id,
      customer_id: sub.customer_id,
      amount_cents: amount_cents,
      description: "Renewal – #{plan.name}",
      issued_at: DateTime.utc_now()
    })
  end
end
```
