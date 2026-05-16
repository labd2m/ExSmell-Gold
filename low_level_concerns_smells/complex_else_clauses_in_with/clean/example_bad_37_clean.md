```elixir
defmodule Billing.SubscriptionRenewal do
  @moduledoc """
  Handles automatic subscription renewals: subscription lookup,
  payment method validation, charge execution, period extension,
  and renewal confirmation.
  """

  alias Billing.{
    SubscriptionRepo,
    PaymentMethodStore,
    ChargeGateway,
    PeriodExtender,
    RenewalMailer
  }

  require Logger

  @doc """
  Renews the subscription identified by `subscription_id`.

  Returns `{:ok, renewed_subscription}` or a structured failure.
  """
  @spec renew_subscription(String.t()) ::
          {:ok, map()}
          | {:error, :subscription_not_found}
          | {:error, :payment_method_invalid}
          | {:error, :charge_failed, String.t()}
          | {:error, :period_extension_failed}
          | {:error, :mailer_failed}
  def renew_subscription(subscription_id) do
    with {:ok, sub}     <- SubscriptionRepo.fetch_renewable(subscription_id),
         {:ok, method}  <- PaymentMethodStore.get_valid(sub.customer_id),
         {:ok, charge}  <- ChargeGateway.charge(method.token, sub.renewal_amount_cents, sub.currency),
         {:ok, renewed} <- PeriodExtender.extend(sub, charge.reference),
         :ok            <- RenewalMailer.send_receipt(sub.customer_id, renewed, charge) do
      Logger.info("Subscription #{subscription_id} renewed, new period ends #{renewed.current_period_end}")
      {:ok, renewed}
    else
      {:error, :not_found} ->
        Logger.warn("Subscription #{subscription_id} not found or not due for renewal")
        {:error, :subscription_not_found}

      {:error, :invalid, reason} ->
        Logger.warn("Payment method invalid for subscription #{subscription_id}: #{reason}")
        {:error, :payment_method_invalid}

      {:declined, code, message} ->
        Logger.info("Charge declined [#{code}]: #{message}")
        {:error, :charge_failed, message}

      {:error, :extend, detail} ->
        Logger.error("Period extension failed: #{inspect(detail)}")
        {:error, :period_extension_failed}

      {:error, :mail} ->
        Logger.error("Renewal receipt email failed for #{subscription_id}")
        {:error, :mailer_failed}
    end
  end
end
```
