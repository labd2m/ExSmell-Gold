```elixir
defmodule Payments.ChargeScheduler do
  @moduledoc """
  Schedules future charges for subscription renewals, instalment plans,
  and deferred payment agreements.

  Scheduled charges are persisted to the charge queue and picked up by
  the nightly charge runner. Each charge is idempotent: re-scheduling
  an already-pending charge for the same billing cycle is a no-op.
  """

  require Logger

  alias Payments.{
    ScheduledCharge,
    ChargeQueue,
    BillingAgreement,
    IdempotencyStore,
    AuditLog
  }

  @max_schedule_horizon_days 365
  @min_amount_cents 100

  @spec schedule(String.t(), map()) ::
          {:ok, ScheduledCharge.t()} | {:error, atom()}
  def schedule(agreement_id, charge_params, dry_run \\ false) do
    with {:ok, agreement} <- BillingAgreement.fetch(agreement_id),
         :ok <- validate_agreement_active(agreement),
         {:ok, charge} <- build_charge(agreement, charge_params),
         :ok <- validate_charge(charge),
         :ok <- check_idempotency(charge) do
      if dry_run do
        Logger.info("Dry-run schedule agreement=#{agreement_id} amount=#{charge.amount_cents}")
        {:ok, %{charge | id: "dry_run", persisted: false}}
      else
        with {:ok, persisted} <- ChargeQueue.enqueue(charge),
             :ok <- IdempotencyStore.record(charge.idempotency_key, persisted.id),
             :ok <-
               AuditLog.record(:charge_scheduled, agreement_id, %{
                 charge_id: persisted.id,
                 scheduled_for: persisted.scheduled_for,
                 amount_cents: persisted.amount_cents
               }) do
          Logger.info(
            "Charge scheduled id=#{persisted.id} agreement=#{agreement_id} " <>
              "amount=#{persisted.amount_cents} for=#{persisted.scheduled_for}"
          )

          {:ok, persisted}
        end
      end
    else
      {:error, :already_scheduled} ->
        Logger.debug("Charge already scheduled agreement=#{agreement_id}, skipping")
        {:error, :already_scheduled}

      {:error, reason} ->
        Logger.error("Schedule failed agreement=#{agreement_id}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @spec cancel(String.t(), String.t()) :: :ok | {:error, atom()}
  def cancel(charge_id, reason) do
    with {:ok, charge} <- ScheduledCharge.fetch(charge_id),
         :ok <- validate_cancellable(charge),
         :ok <- ChargeQueue.remove(charge_id),
         :ok <- AuditLog.record(:charge_cancelled, charge.agreement_id, %{reason: reason}) do
      Logger.info("Scheduled charge cancelled id=#{charge_id} reason=#{reason}")
      :ok
    end
  end

  defp build_charge(%BillingAgreement{} = agreement, params) do
    scheduled_for = Map.fetch!(params, :scheduled_for)
    amount_cents = Map.get(params, :amount_cents, agreement.default_amount_cents)
    idempotency_key = "#{agreement.id}:#{Date.to_iso8601(scheduled_for)}"

    charge = %ScheduledCharge{
      agreement_id: agreement.id,
      customer_id: agreement.customer_id,
      payment_method_id: agreement.payment_method_id,
      amount_cents: amount_cents,
      currency: agreement.currency,
      scheduled_for: scheduled_for,
      idempotency_key: idempotency_key,
      status: :pending
    }

    {:ok, charge}
  end

  defp validate_charge(%ScheduledCharge{amount_cents: cents}) when cents < @min_amount_cents,
    do: {:error, :amount_below_minimum}

  defp validate_charge(%ScheduledCharge{scheduled_for: date}) do
    max_date = Date.add(Date.utc_today(), @max_schedule_horizon_days)

    if Date.compare(date, max_date) == :gt do
      {:error, :schedule_too_far_ahead}
    else
      :ok
    end
  end

  defp validate_agreement_active(%BillingAgreement{status: :active}), do: :ok
  defp validate_agreement_active(_), do: {:error, :agreement_inactive}

  defp validate_cancellable(%ScheduledCharge{status: :pending}), do: :ok
  defp validate_cancellable(_), do: {:error, :not_cancellable}

  defp check_idempotency(%ScheduledCharge{idempotency_key: key}) do
    case IdempotencyStore.lookup(key) do
      {:ok, _existing_id} -> {:error, :already_scheduled}
      {:error, :not_found} -> :ok
    end
  end
end

defmodule Payments.SubscriptionRenewer do
  alias Payments.{ChargeScheduler, BillingAgreement}

  require Logger

  def schedule_upcoming_renewals(lookahead_days \\ 7) do
    due_date = Date.add(Date.utc_today(), lookahead_days)

    BillingAgreement.list_renewing_on(due_date)
    |> Enum.each(fn agreement ->
      ChargeScheduler.schedule(agreement.id, %{
        scheduled_for: due_date,
        amount_cents: agreement.default_amount_cents
      })
    end)
  end
end
```
