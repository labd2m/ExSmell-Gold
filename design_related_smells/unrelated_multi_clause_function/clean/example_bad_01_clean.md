```elixir
defmodule BillingProcessor do
  @moduledoc """
  Handles billing-related operations including invoices, refunds, and subscriptions.
  """

  alias BillingProcessor.{Invoice, Refund, Subscription, Repo, Mailer}

  @doc """
  Processes a billing entity.

  ## Examples

      iex> BillingProcessor.process(%Invoice{})
      {:ok, %Invoice{status: :paid}}

  """


  def process(%Invoice{status: :pending, amount: amount, customer_id: customer_id} = invoice)
      when is_float(amount) and amount > 0.0 do
    with {:ok, charge} <- PaymentGateway.charge(customer_id, amount),
         {:ok, updated} <-
           Repo.update(Invoice.changeset(invoice, %{status: :paid, charge_id: charge.id})) do
      Mailer.send_receipt(updated)
      {:ok, updated}
    else
      {:error, :insufficient_funds} -> {:error, :payment_failed}
      {:error, reason} -> {:error, reason}
    end
  end

  # handles refund for an approved refund request
  def process(%Refund{status: :approved, original_charge_id: charge_id, amount: amount} = refund)
      when is_float(amount) and amount > 0.0 do
    with {:ok, _reversal} <- PaymentGateway.reverse_charge(charge_id, amount),
         {:ok, updated} <-
           Repo.update(Refund.changeset(refund, %{status: :completed, processed_at: DateTime.utc_now()})) do
      Mailer.send_refund_confirmation(updated)
      {:ok, updated}
    else
      {:error, :charge_not_found} -> {:error, :invalid_original_charge}
      {:error, reason} -> {:error, reason}
    end
  end

  # activates a newly purchased subscription
  def process(%Subscription{status: :inactive, plan: plan, account_id: account_id} = subscription)
      when plan in [:basic, :pro, :enterprise] do
    features = plan_features(plan)

    with {:ok, provisioned} <- FeatureProvisioner.enable(account_id, features),
         {:ok, updated} <-
           Repo.update(
             Subscription.changeset(subscription, %{
               status: :active,
               activated_at: DateTime.utc_now(),
               features: provisioned.feature_list
             })
           ) do
      Mailer.send_subscription_welcome(updated)
      {:ok, updated}
    else
      {:error, reason} -> {:error, reason}
    end
  end


  defp plan_features(:basic), do: [:reports, :api_access]
  defp plan_features(:pro), do: [:reports, :api_access, :priority_support, :custom_domains]
  defp plan_features(:enterprise), do: [:reports, :api_access, :priority_support, :custom_domains, :sso, :audit_logs]
end
```
