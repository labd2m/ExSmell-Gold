```elixir
defmodule MyApp.Payments.RecurringChargeJob do
  @moduledoc """
  An Oban worker that processes a single recurring charge attempt for
  a subscription. It validates the subscription is still active, fetches
  the customer's default payment method, attempts the charge through the
  payment gateway, and updates the subscription state accordingly.

  Each job handles exactly one subscription; the scheduler enqueues one
  job per due subscription from a separate orchestration job.
  """

  use Oban.Worker,
    queue: :billing,
    max_attempts: 3,
    unique: [period: 86_400, fields: [:args]]

  require Logger

  alias MyApp.Repo
  alias MyApp.Subscriptions.{Subscription, BillingCycle}
  alias MyApp.Payments.Gateway
  alias MyApp.Billing.{Payment, InvoiceNumberSequence}
  alias MyApp.Events

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"subscription_id" => sub_id}}) do
    case Repo.get(Subscription, sub_id) do
      nil ->
        Logger.warning("recurring_charge_subscription_not_found", id: sub_id)
        :ok

      %Subscription{status: :cancelled} ->
        Logger.info("recurring_charge_subscription_cancelled", id: sub_id)
        :ok

      subscription ->
        process_charge(subscription)
    end
  end

  @spec process_charge(Subscription.t()) :: :ok | {:error, term()}
  defp process_charge(subscription) do
    with {:ok, amount_cents} <- resolve_amount(subscription),
         {:ok, charge_id} <- attempt_charge(subscription, amount_cents),
         {:ok, invoice_number} <- {:ok, InvoiceNumberSequence.next()},
         {:ok, _payment} <- record_payment(subscription, charge_id, amount_cents, invoice_number),
         {:ok, _sub} <- advance_subscription(subscription) do
      Events.broadcast(%Events.PaymentConfirmed{
        order_id: subscription.id,
        transaction_id: charge_id,
        amount_cents: amount_cents,
        occurred_at: DateTime.utc_now()
      })

      Logger.info("recurring_charge_succeeded",
        subscription_id: subscription.id,
        amount_cents: amount_cents,
        invoice: invoice_number
      )

      :ok
    else
      {:error, reason} ->
        Logger.error("recurring_charge_failed",
          subscription_id: subscription.id,
          reason: inspect(reason)
        )

        mark_payment_failed(subscription, reason)
        {:error, reason}
    end
  end

  @spec resolve_amount(Subscription.t()) :: {:ok, pos_integer()} | {:error, term()}
  defp resolve_amount(subscription) do
    case BillingCycle.amount_due(subscription) do
      {:ok, amount} when amount > 0 -> {:ok, amount}
      {:ok, _} -> {:error, :no_amount_due}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec attempt_charge(Subscription.t(), pos_integer()) :: {:ok, String.t()} | {:error, term()}
  defp attempt_charge(subscription, amount_cents) do
    Gateway.charge(
      subscription.customer_id,
      amount_cents,
      subscription.default_payment_method_id,
      idempotency_key: "sub_#{subscription.id}_#{subscription.current_period_end}"
    )
  end

  @spec record_payment(Subscription.t(), String.t(), pos_integer(), String.t()) ::
          {:ok, Payment.t()} | {:error, Ecto.Changeset.t()}
  defp record_payment(subscription, charge_id, amount_cents, invoice_number) do
    %Payment{}
    |> Payment.changeset(%{
      subscription_id: subscription.id,
      customer_id: subscription.customer_id,
      amount_cents: amount_cents,
      provider_charge_id: charge_id,
      invoice_number: invoice_number,
      status: :captured,
      captured_at: DateTime.utc_now()
    })
    |> Repo.insert()
  end

  @spec advance_subscription(Subscription.t()) ::
          {:ok, Subscription.t()} | {:error, Ecto.Changeset.t()}
  defp advance_subscription(subscription) do
    subscription
    |> Subscription.advance_cycle_changeset()
    |> Repo.update()
  end

  @spec mark_payment_failed(Subscription.t(), term()) :: :ok
  defp mark_payment_failed(subscription, reason) do
    subscription
    |> Subscription.past_due_changeset(%{failure_reason: inspect(reason)})
    |> Repo.update()

    :ok
  end
end
```
