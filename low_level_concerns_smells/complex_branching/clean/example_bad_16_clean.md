# example_bad_16_clean

```elixir
defmodule Payments.SubscriptionRenewer do
  @moduledoc """
  Handles subscription renewal cycles by invoking the billing provider
  and applying the appropriate subscription state transitions.
  """

  alias Payments.SubscriptionBillingClient
  alias Payments.SubscriptionStore
  alias Payments.DunningWorkflow
  alias Payments.GracePeriodManager
  alias Payments.TaxComplianceLog
  alias Notifications.EmailDispatcher
  alias Payments.AuditLogger

  @grace_period_days 7
  @dunning_retry_hours 24

  def renew(subscription_id, operator_id) do
    with {:ok, sub} <- SubscriptionStore.fetch(subscription_id),
         :ok <- assert_renewable(sub),
         {:ok, result} <- process_renewal_response(sub, operator_id, %{}),
         :ok <- SubscriptionStore.record_renewal_attempt(subscription_id, result) do
      {:ok, result}
    end
  end

  defp process_renewal_response(sub, operator_id, metadata) do
    case SubscriptionBillingClient.renew(sub.billing_ref, %{plan: sub.plan_id, metadata: metadata}) do
      {:ok, %{status: "renewed", invoice_id: inv, next_renewal_at: nra, amount_charged: amt}} ->
        SubscriptionStore.update_renewal(sub.id, %{next_renewal_at: nra, last_invoice: inv})
        EmailDispatcher.send_renewal_receipt(sub.customer_email, inv, amt)
        AuditLogger.log(:subscription_renewed, operator_id, %{sub_id: sub.id, invoice: inv})
        {:ok, %{status: :renewed, invoice_id: inv, next_renewal_at: nra}}

      {:ok, %{status: "grace_period", reason: reason, grace_until: gu}} ->
        GracePeriodManager.start(sub.id, gu, reason)
        SubscriptionStore.set_status(sub.id, :grace_period)
        EmailDispatcher.send_grace_period_notice(sub.customer_email, gu)
        {:ok, %{status: :grace_period, grace_until: gu, reason: reason}}

      {:ok, %{status: "failed", reason: "payment_declined", decline_code: dc}} ->
        DunningWorkflow.initiate(sub.id, dc, @dunning_retry_hours)
        SubscriptionStore.set_status(sub.id, :past_due)
        EmailDispatcher.send_payment_failed(sub.customer_email, dc)
        AuditLogger.log(:payment_declined, operator_id, %{sub_id: sub.id, code: dc})
        {:error, {:payment_declined, dc}}

      {:ok, %{status: "failed", reason: "customer_cancelled", cancelled_at: cat}} ->
        SubscriptionStore.set_status(sub.id, :cancelled)
        EmailDispatcher.send_cancellation_confirmed(sub.customer_email, cat)
        AuditLogger.log(:subscription_cancelled, operator_id, %{sub_id: sub.id, at: cat})
        {:error, {:customer_cancelled, cat}}

      {:ok, %{status: "failed", reason: "plan_unavailable", plan_id: pid}} ->
        SubscriptionStore.set_status(sub.id, :suspended)
        AuditLogger.log(:plan_unavailable, operator_id, %{sub_id: sub.id, plan_id: pid})
        {:error, {:plan_unavailable, pid}}

      {:ok, %{status: "failed", reason: "proration_conflict", conflict_ref: cref}} ->
        AuditLogger.log(:proration_conflict, operator_id, %{sub_id: sub.id, ref: cref})
        {:error, {:proration_conflict, cref}}

      {:ok, %{status: "failed", reason: "tax_calculation_error", jurisdiction: jur}} ->
        TaxComplianceLog.record_failure(sub.id, jur)
        {:error, {:tax_calculation_error, jur}}

      {:ok, %{status: "failed", reason: "currency_conversion_error", from: fc, to: tc}} ->
        AuditLogger.log(:currency_conversion_error, operator_id, %{sub_id: sub.id, from: fc, to: tc})
        {:error, {:currency_conversion_error, %{from: fc, to: tc}}}

      {:ok, %{status: "failed", reason: other}} ->
        AuditLogger.log(:renewal_unknown_failure, operator_id, %{sub_id: sub.id, reason: other})
        {:error, {:renewal_failed, other}}

      {:error, %{reason: :timeout}} ->
        {:error, :billing_provider_timeout}

      {:error, reason} ->
        AuditLogger.log(:billing_provider_error, operator_id, %{sub_id: sub.id, reason: reason})
        {:error, :billing_provider_error}
    end
  end

  defp assert_renewable(%{status: status}) when status in [:active, :grace_period], do: :ok
  defp assert_renewable(%{status: status}), do: {:error, {:not_renewable, status}}
end
```
