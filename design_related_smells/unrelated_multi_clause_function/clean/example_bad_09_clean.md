```elixir
defmodule BillingProcessor do
  @moduledoc """
  Handles billing operations for the platform, including invoice processing,
  refunds, and subscription lifecycle management.
  """

  alias BillingProcessor.{Invoice, Refund, Subscription, Ledger, Mailer}

  @doc """
  Process a billing event.

  Accepts an `%Invoice{}`, `%Refund{}`, or `%Subscription{}` struct and
  dispatches the appropriate billing action.

  ## Examples

      iex> BillingProcessor.process(%Invoice{amount: 150_00, currency: "USD"})
      {:ok, %Invoice{status: :paid}}

  """

  def process(%Invoice{status: :pending, amount: amount, customer_id: customer_id} = invoice)
      when is_integer(amount) and amount > 0 do
    with {:ok, payment} <- charge_customer(customer_id, amount, invoice.currency),
         {:ok, updated} <- mark_invoice_paid(invoice, payment.transaction_id),
         :ok <- Ledger.record_credit(customer_id, amount, invoice.id),
         :ok <- Mailer.send_receipt(customer_id, updated) do
      {:ok, updated}
    else
      {:error, :insufficient_funds} ->
        mark_invoice_failed(invoice, "insufficient_funds")

      {:error, reason} ->
        {:error, reason}
    end
  end

  # process refund for approved refund request
  def process(%Refund{status: :approved, original_invoice_id: inv_id, amount: amount} = refund) do
    with {:ok, invoice} <- fetch_invoice(inv_id),
         true <- invoice.status == :paid,
         {:ok, _} <- reverse_charge(invoice.customer_id, amount, refund.reason),
         {:ok, updated} <- mark_refund_issued(refund),
         :ok <- Ledger.record_debit(invoice.customer_id, amount, inv_id),
         :ok <- Mailer.send_refund_confirmation(invoice.customer_id, updated) do
      {:ok, updated}
    else
      false -> {:error, :invoice_not_paid}
      {:error, reason} -> {:error, reason}
    end
  end

  # process subscription renewal for active subscriptions
  def process(%Subscription{status: :active, renews_at: renews_at, plan: plan} = subscription)
      when not is_nil(renews_at) do
    today = Date.utc_today()

    if Date.compare(renews_at, today) != :gt do
      with {:ok, new_invoice} <- create_renewal_invoice(subscription),
           {:ok, _} <- process(new_invoice),
           {:ok, updated_sub} <-
             update_subscription_renewal(subscription, plan.billing_interval) do
        {:ok, updated_sub}
      end
    else
      {:ok, :not_due}
    end
  end


  ## Private helpers

  defp charge_customer(customer_id, amount, currency) do
    # Calls payment gateway
    PaymentGateway.charge(%{
      customer_id: customer_id,
      amount: amount,
      currency: currency
    })
  end

  defp reverse_charge(customer_id, amount, reason) do
    PaymentGateway.refund(%{
      customer_id: customer_id,
      amount: amount,
      reason: reason
    })
  end

  defp mark_invoice_paid(invoice, transaction_id) do
    invoice
    |> Map.put(:status, :paid)
    |> Map.put(:transaction_id, transaction_id)
    |> Map.put(:paid_at, DateTime.utc_now())
    |> Repo.update()
  end

  defp mark_invoice_failed(invoice, reason) do
    invoice
    |> Map.put(:status, :failed)
    |> Map.put(:failure_reason, reason)
    |> Repo.update()
  end

  defp mark_refund_issued(refund) do
    refund
    |> Map.put(:status, :issued)
    |> Map.put(:issued_at, DateTime.utc_now())
    |> Repo.update()
  end

  defp fetch_invoice(id), do: Repo.fetch(Invoice, id)

  defp create_renewal_invoice(subscription) do
    %Invoice{
      customer_id: subscription.customer_id,
      amount: subscription.plan.price,
      currency: subscription.plan.currency,
      status: :pending
    }
    |> Repo.insert()
  end

  defp update_subscription_renewal(subscription, interval) do
    new_date = Date.add(subscription.renews_at, interval_days(interval))

    subscription
    |> Map.put(:renews_at, new_date)
    |> Repo.update()
  end

  defp interval_days(:monthly), do: 30
  defp interval_days(:yearly), do: 365
  defp interval_days(_), do: 30
end
```
