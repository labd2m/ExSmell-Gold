```elixir
defmodule MyApp.PaymentOrchestrator do
  @moduledoc """
  Orchestrates payment-related operations including customer charges,
  vendor payouts, and chargeback reconciliation.
  """

  require Logger

  alias MyApp.Repo
  alias MyApp.Payments.{Charge, Payout, Chargeback}
  alias MyApp.Integrations.StripeClient
  alias MyApp.Finance.Ledger
  alias MyApp.Notifications.Mailer

  @chargeback_auto_accept_threshold_usd 25.0

  @doc """
  Runs a payment operation.

  Accepts a `%Charge{}`, `%Payout{}`, or `%Chargeback{}` struct.

  ## Examples

      iex> MyApp.PaymentOrchestrator.run(%Charge{amount: 4999, currency: "USD", customer_id: "cus_abc"})
      {:ok, %Charge{status: :succeeded}}

  """

  def run(%Charge{
        amount: amount,
        currency: currency,
        customer_id: customer_id,
        payment_method_id: pm_id,
        idempotency_key: idem_key
      } = charge)
      when is_integer(amount) and amount > 0 do
    Logger.info("Charging customer #{customer_id}, #{amount} #{currency}")

    case StripeClient.create_payment_intent(%{
           amount: amount,
           currency: String.downcase(currency),
           customer: customer_id,
           payment_method: pm_id,
           confirm: true,
           idempotency_key: idem_key
         }) do
      {:ok, %{id: pi_id, status: "succeeded"}} ->
        {:ok, updated} =
          Repo.update(
            Charge.changeset(charge, %{
              status: :succeeded,
              stripe_payment_intent_id: pi_id,
              captured_at: DateTime.utc_now()
            })
          )

        Ledger.record_credit(customer_id, amount, currency, pi_id)
        Mailer.send_payment_receipt(customer_id, updated)
        Logger.info("Charge succeeded for customer #{customer_id}, pi: #{pi_id}")
        {:ok, updated}

      {:ok, %{id: pi_id, status: "requires_action"}} ->
        Repo.update!(Charge.changeset(charge, %{status: :requires_action, stripe_payment_intent_id: pi_id}))
        {:error, :requires_action}

      {:error, %{code: "card_declined"}} ->
        Repo.update!(Charge.changeset(charge, %{status: :failed}))
        Logger.warn("Card declined for customer #{customer_id}")
        {:error, :card_declined}

      {:error, reason} ->
        Logger.error("Charge failed for customer #{customer_id}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  def run(%Payout{
        vendor_id: vendor_id,
        amount: amount,
        currency: currency,
        stripe_account_id: stripe_acct,
        scheduled_for: scheduled_for
      } = payout)
      when is_integer(amount) and amount > 0 do
    Logger.info("Processing payout of #{amount} #{currency} to vendor #{vendor_id}")

    if DateTime.compare(scheduled_for, DateTime.utc_now()) == :gt do
      Logger.info("Payout for vendor #{vendor_id} is scheduled for future: #{scheduled_for}")
      {:ok, :scheduled}
    else
      case StripeClient.create_transfer(%{
             amount: amount,
             currency: String.downcase(currency),
             destination: stripe_acct
           }) do
        {:ok, %{id: transfer_id}} ->
          {:ok, updated} =
            Repo.update(
              Payout.changeset(payout, %{
                status: :paid,
                stripe_transfer_id: transfer_id,
                paid_at: DateTime.utc_now()
              })
            )

          Ledger.record_debit(:vendor_payout, vendor_id, amount, currency, transfer_id)
          Logger.info("Payout #{transfer_id} completed for vendor #{vendor_id}")
          {:ok, updated}

        {:error, reason} ->
          Repo.update!(Payout.changeset(payout, %{status: :failed}))
          Logger.error("Payout failed for vendor #{vendor_id}: #{inspect(reason)}")
          {:error, reason}
      end
    end
  end

  def run(%Chargeback{
        charge_id: charge_id,
        amount: amount,
        stripe_dispute_id: dispute_id,
        status: :open
      } = chargeback) do
    Logger.info("Handling chargeback #{dispute_id} for charge #{charge_id}, amount: #{amount}")

    original_charge = Repo.get!(Charge, charge_id)

    if amount / 100.0 <= @chargeback_auto_accept_threshold_usd do
      Logger.info("Auto-accepting chargeback #{dispute_id} below threshold")

      case StripeClient.accept_dispute(dispute_id) do
        {:ok, _} ->
          {:ok, updated} =
            Repo.update(
              Chargeback.changeset(chargeback, %{
                status: :accepted,
                resolution: :auto_accepted,
                resolved_at: DateTime.utc_now()
              })
            )

          Ledger.record_chargeback_loss(original_charge.customer_id, amount, dispute_id)
          {:ok, updated}

        {:error, reason} ->
          Logger.error("Failed to accept dispute #{dispute_id}: #{inspect(reason)}")
          {:error, reason}
      end
    else
      Logger.info("Flagging chargeback #{dispute_id} for manual review")

      {:ok, updated} =
        Repo.update(Chargeback.changeset(chargeback, %{status: :under_review}))

      Mailer.notify_finance_team_chargeback(updated)
      {:ok, :flagged_for_review}
    end
  end

end
```
