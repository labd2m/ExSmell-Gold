# Annotated Example — Smell: Unrelated multi-clause function

## Metadata

- **Smell name:** Unrelated multi-clause function
- **Expected smell location:** `BillingProcessor.process/1`
- **Affected function(s):** `process/1`
- **Short explanation:** The `process/1` function uses multi-clause pattern matching to handle completely unrelated business entities: invoices, refunds, and subscription renewals. Each clause deals with a distinct domain concept with its own logic, side effects, and rules — they are not variations of the same operation but rather three separate operations forced into a single function name.

---

```elixir
defmodule MyApp.BillingProcessor do
  @moduledoc """
  Handles all billing-related processing tasks including invoices,
  refunds, and subscription renewals.
  """

  require Logger

  alias MyApp.Repo
  alias MyApp.Billing.{Invoice, Refund, Subscription}
  alias MyApp.Notifications.Mailer
  alias MyApp.Payments.Gateway

  @max_refund_days 30
  @renewal_grace_period_days 3

  @doc """
  Processes a billing entity.

  Accepts an `%Invoice{}`, a `%Refund{}`, or a `%Subscription{}` struct
  and performs the appropriate action.

  ## Examples

      iex> MyApp.BillingProcessor.process(%Invoice{status: :pending, total: 150.00})
      {:ok, %Invoice{status: :paid}}

  """

  # VALIDATION: SMELL START - Unrelated multi-clause function
  # VALIDATION: This is a smell because the three clauses handle completely
  # unrelated domain concepts (invoices, refunds, subscriptions). Each has its
  # own rules, side effects, and error paths. They share only a name, not logic.

  def process(%Invoice{status: :pending, total: total, customer_id: customer_id} = invoice)
      when is_float(total) and total > 0.0 do
    Logger.info("Processing pending invoice for customer #{customer_id}, total: #{total}")

    with {:ok, payment} <- Gateway.charge(customer_id, total),
         {:ok, updated} <-
           Repo.update(Invoice.changeset(invoice, %{status: :paid, payment_ref: payment.id})) do
      Mailer.send_invoice_receipt(updated)
      {:ok, updated}
    else
      {:error, :insufficient_funds} ->
        Logger.warn("Insufficient funds for customer #{customer_id}")
        Repo.update(Invoice.changeset(invoice, %{status: :failed}))
        {:error, :insufficient_funds}

      {:error, reason} ->
        Logger.error("Invoice processing failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  def process(%Refund{
        invoice_id: invoice_id,
        amount: amount,
        requested_at: requested_at,
        status: :pending
      } = refund) do
    invoice = Repo.get!(Invoice, invoice_id)
    days_since = Date.diff(Date.utc_today(), NaiveDateTime.to_date(requested_at))

    cond do
      days_since > @max_refund_days ->
        Logger.warn("Refund request for invoice #{invoice_id} is outside the allowed window")
        {:error, :outside_refund_window}

      amount > invoice.total ->
        Logger.warn("Refund amount #{amount} exceeds invoice total #{invoice.total}")
        {:error, :exceeds_original_amount}

      true ->
        with {:ok, _gateway_refund} <- Gateway.refund(invoice.payment_ref, amount),
             {:ok, updated} <-
               Repo.update(Refund.changeset(refund, %{status: :approved, processed_at: DateTime.utc_now()})) do
          Mailer.send_refund_confirmation(updated)
          {:ok, updated}
        end
    end
  end

  def process(
        %Subscription{
          status: :active,
          renews_at: renews_at,
          plan: plan,
          customer_id: customer_id
        } = subscription
      ) do
    days_until_renewal = Date.diff(NaiveDateTime.to_date(renews_at), Date.utc_today())

    if days_until_renewal > @renewal_grace_period_days do
      Logger.debug("Subscription for customer #{customer_id} not yet due for renewal")
      {:ok, :not_due}
    else
      plan_price = fetch_plan_price(plan)
      Logger.info("Renewing #{plan} subscription for customer #{customer_id}")

      with {:ok, payment} <- Gateway.charge(customer_id, plan_price),
           {:ok, updated} <-
             Repo.update(
               Subscription.changeset(subscription, %{
                 renews_at: next_renewal_date(renews_at, plan),
                 last_payment_ref: payment.id
               })
             ) do
        Mailer.send_renewal_confirmation(updated)
        {:ok, updated}
      else
        {:error, :payment_declined} ->
          Repo.update(Subscription.changeset(subscription, %{status: :past_due}))
          Mailer.send_payment_failed_notice(customer_id)
          {:error, :payment_declined}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  # VALIDATION: SMELL END

  defp fetch_plan_price(:basic), do: 9.99
  defp fetch_plan_price(:pro), do: 29.99
  defp fetch_plan_price(:enterprise), do: 99.99

  defp next_renewal_date(renews_at, :basic), do: NaiveDateTime.add(renews_at, 30, :day)
  defp next_renewal_date(renews_at, :pro), do: NaiveDateTime.add(renews_at, 30, :day)
  defp next_renewal_date(renews_at, :enterprise), do: NaiveDateTime.add(renews_at, 365, :day)
end
```
