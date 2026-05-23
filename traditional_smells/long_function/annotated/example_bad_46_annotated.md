# Annotated Example — Code Smell: Long Function

## Metadata

- **Smell name:** Long Function
- **Expected smell location:** `Billing.SubscriptionRenewalService.renew/2`
- **Affected function(s):** `renew/2`
- **Short explanation:** `renew/2` handles expiry-window validation, trial-period detection, payment-method retrieval, charge attempt with retry, grace-period enforcement, subscription-record update, usage-counter reset, invoice creation, and renewal-confirmation email — all sequenced inside one function body far exceeding ten lines with no helper delegation.

---

```elixir
defmodule Billing.SubscriptionRenewalService do
  @moduledoc """
  Handles automatic subscription renewals including payment
  retry, grace-period enforcement, and invoice generation.
  """

  require Logger

  alias Billing.{
    Subscription, PaymentMethod, ChargeGateway,
    GracePeriod, Invoice, UsageCounter, Mailer
  }

  @renewal_window_days   3
  @max_charge_attempts   3
  @retry_delay_ms        1_000
  @grace_period_days     7

  # VALIDATION: SMELL START - Long Function
  # VALIDATION: This is a smell because `renew/2` sequences expiry-window
  # checking, trial detection, payment-method lookup, charge retry loop,
  # grace-period creation on failure, subscription-record update, usage
  # reset, invoice persistence, and customer notification — nine distinct
  # responsibilities crammed into one function body of over 110 lines
  # without extracting any concern into a focused private helper.
  def renew(%Subscription{} = sub, opts \\ []) do
    force    = Keyword.get(opts, :force, false)
    operator = Keyword.get(opts, :operator, "renewal_worker")

    Logger.info("Attempting renewal for subscription #{sub.id} (#{sub.customer_email})")

    # 1. Guard: only renew subscriptions expiring within the renewal window
    days_until_expiry = Date.diff(sub.current_period_end, Date.utc_today())

    unless force or days_until_expiry <= @renewal_window_days do
      Logger.debug("Subscription #{sub.id} not yet within renewal window (#{days_until_expiry}d)")
      {:skip, :not_in_window}
    else
      # 2. Skip trial subscriptions — they transition via a separate flow
      if sub.status == :trialing do
        Logger.info("Subscription #{sub.id} is trialing — skipping auto-renewal")
        {:skip, :trialing}
      else
        # 3. Load the customer's active payment method
        payment_method =
          case PaymentMethod.default_for_customer(sub.customer_id) do
            nil ->
              Logger.warning("No payment method for customer #{sub.customer_id}")
              nil

            pm ->
              pm
          end

        unless payment_method do
          GracePeriod.open(%{
            subscription_id: sub.id,
            reason:          :no_payment_method,
            expires_at:      Date.add(Date.utc_today(), @grace_period_days)
          })

          Subscription.update(sub.id, %{status: :past_due, updated_at: DateTime.utc_now()})
          {:error, :no_payment_method}
        else
          # 4. Attempt charge with retries
          amount_cents = sub.plan_price_cents

          charge_result =
            Enum.reduce_while(1..@max_charge_attempts, {:error, :not_attempted}, fn attempt, _acc ->
              if attempt > 1 do
                Logger.info("Retry #{attempt} for subscription #{sub.id}")
                Process.sleep(@retry_delay_ms * attempt)
              end

              case ChargeGateway.charge(payment_method.gateway_token, %{
                amount_cents: amount_cents,
                currency:     sub.currency,
                description:  "Subscription renewal — #{sub.plan_name}",
                metadata:     %{subscription_id: sub.id, customer_id: sub.customer_id}
              }) do
                {:ok, charge} ->
                  {:halt, {:ok, charge}}

                {:error, %{retryable: true} = err} when attempt < @max_charge_attempts ->
                  Logger.warning("Retryable charge error on attempt #{attempt}: #{inspect(err)}")
                  {:cont, {:error, err}}

                {:error, err} ->
                  {:halt, {:error, err}}
              end
            end)

          case charge_result do
            {:error, reason} ->
              Logger.error("All charge attempts failed for #{sub.id}: #{inspect(reason)}")

              # 5. Open grace period on charge failure
              GracePeriod.open(%{
                subscription_id: sub.id,
                reason:          :charge_failed,
                expires_at:      Date.add(Date.utc_today(), @grace_period_days)
              })

              Subscription.update(sub.id, %{status: :past_due, updated_at: DateTime.utc_now()})

              {:error, {:charge_failed, reason}}

            {:ok, charge} ->
              new_period_start = sub.current_period_end
              new_period_end   = Date.add(new_period_start, sub.billing_interval_days)

              # 6. Update the subscription record
              case Subscription.update(sub.id, %{
                status:              :active,
                current_period_start: new_period_start,
                current_period_end:   new_period_end,
                renewed_at:           DateTime.utc_now(),
                renewal_count:        sub.renewal_count + 1
              }) do
                {:error, reason} ->
                  Logger.error("Subscription update failed after charge: #{inspect(reason)}")
                  {:error, :subscription_update_failed}

                {:ok, updated_sub} ->
                  # 7. Reset usage counters for metered features
                  sub.metered_features
                  |> Enum.each(fn feature ->
                    case UsageCounter.reset(sub.id, feature) do
                      :ok              -> :ok
                      {:error, reason} ->
                        Logger.warning("Usage reset failed #{feature}: #{inspect(reason)}")
                    end
                  end)

                  # 8. Generate renewal invoice
                  invoice_attrs = %{
                    subscription_id:  sub.id,
                    customer_id:      sub.customer_id,
                    charge_id:        charge.id,
                    amount_cents:     amount_cents,
                    currency:         sub.currency,
                    period_start:     new_period_start,
                    period_end:       new_period_end,
                    status:           :paid,
                    issued_at:        DateTime.utc_now()
                  }

                  case Invoice.insert(invoice_attrs) do
                    {:error, reason} ->
                      Logger.warning("Invoice creation failed for #{sub.id}: #{inspect(reason)}")

                    {:ok, invoice} ->
                      Logger.info("Invoice #{invoice.id} created for renewal of #{sub.id}")
                  end

                  # 9. Send renewal confirmation e-mail
                  email_body = """
                  Hi #{sub.customer_name},

                  Your subscription to #{sub.plan_name} has been successfully renewed.

                  Amount charged : $#{Float.round(amount_cents / 100, 2)} #{String.upcase(sub.currency)}
                  Next renewal   : #{new_period_end}
                  Payment method : •••• #{payment_method.last4}

                  Manage your subscription at https://app.example.com/billing
                  """

                  case Mailer.send_email(sub.customer_email, "Subscription Renewed", email_body) do
                    {:ok, _}         -> :ok
                    {:error, reason} ->
                      Logger.warning("Renewal email failed for #{sub.id}: #{inspect(reason)}")
                  end

                  Logger.info("Subscription #{sub.id} renewed successfully by #{operator}")
                  {:ok, updated_sub}
              end
          end
        end
      end
    end
  end
  # VALIDATION: SMELL END
end
```
