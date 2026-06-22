```elixir
defmodule MyApp.Payments.ChargebackHandler do
  @moduledoc """
  Processes inbound chargeback notifications from payment processors.
  When a chargeback is received the handler reverses the affected revenue
  recognition entries in the ledger, flags the customer account for
  review, and schedules a dispute evidence job if the chargeback falls
  within the dispute window. All side effects are orchestrated via
  `Ecto.Multi` for atomicity.
  """

  alias Ecto.Multi
  alias MyApp.Repo
  alias MyApp.Billing.{Payment, LedgerEntry}
  alias MyApp.Accounts.User
  alias MyApp.Compliance.AuditLogger

  import Ecto.Query, warn: false

  @dispute_window_days 60

  @type chargeback_event :: %{
          required(:provider_charge_id) => String.t(),
          required(:amount_cents) => pos_integer(),
          required(:reason_code) => String.t(),
          required(:dispute_deadline) => Date.t() | nil
        }

  @doc """
  Processes `event`, reversing the ledger, flagging the account, and
  optionally scheduling dispute evidence collection. Returns
  `{:ok, result_map}` or a failed Multi tuple.
  """
  @spec process(chargeback_event()) ::
          {:ok, map()} | {:error, atom(), term(), map()} | {:error, :payment_not_found}
  def process(%{provider_charge_id: charge_id} = event) do
    case Repo.get_by(Payment, provider_charge_id: charge_id) do
      nil ->
        {:error, :payment_not_found}

      payment ->
        run_chargeback_multi(payment, event)
    end
  end

  @spec run_chargeback_multi(Payment.t(), chargeback_event()) ::
          {:ok, map()} | {:error, atom(), term(), map()}
  defp run_chargeback_multi(payment, event) do
    Multi.new()
    |> Multi.run(:mark_payment, fn _repo, _ ->
      payment
      |> Payment.chargeback_changeset(%{
        status: :chargedback,
        chargeback_reason: event.reason_code,
        chargedback_at: DateTime.utc_now()
      })
      |> Repo.update()
    end)
    |> Multi.run(:ledger_reversal, fn _repo, _ ->
      LedgerEntry.record_transfer(
        %{type: :revenue, id: "revenue"},
        %{type: :chargeback_liability, id: payment.customer_id},
        "Chargeback reversal: #{event.reason_code}",
        event.amount_cents,
        "usd"
      )
    end)
    |> Multi.run(:flag_customer, fn _repo, _ ->
      flag_customer_for_review(payment.customer_id)
    end)
    |> Multi.run(:audit, fn _repo, %{mark_payment: updated_payment} ->
      AuditLogger.log(
        %{id: "system", type: :system},
        "chargeback.processed",
        %{id: updated_payment.id, type: "payment"},
        %{reason_code: event.reason_code, amount_cents: event.amount_cents}
      )

      {:ok, :logged}
    end)
    |> Repo.transaction()
    |> maybe_schedule_dispute(event)
  end

  @spec flag_customer_for_review(String.t()) ::
          {:ok, User.t()} | {:error, Ecto.Changeset.t()}
  defp flag_customer_for_review(customer_id) do
    case Repo.get(User, customer_id) do
      nil ->
        {:ok, :customer_not_found}

      user ->
        user
        |> User.changeset(%{review_flag: :chargeback, review_flagged_at: DateTime.utc_now()})
        |> Repo.update()
    end
  end

  @spec maybe_schedule_dispute({:ok, map()} | {:error, term()}, chargeback_event()) ::
          {:ok, map()} | {:error, atom(), term(), map()}
  defp maybe_schedule_dispute({:error, _} = error, _event), do: error

  defp maybe_schedule_dispute({:ok, changes}, event) do
    if disputable?(event) do
      MyApp.Workers.DisputeEvidenceWorker.new(%{
        provider_charge_id: event.provider_charge_id,
        deadline: Date.to_iso8601(event.dispute_deadline)
      })
      |> Oban.insert()
    end

    {:ok, changes}
  end

  @spec disputable?(chargeback_event()) :: boolean()
  defp disputable?(%{dispute_deadline: nil}), do: false

  defp disputable?(%{dispute_deadline: deadline}) do
    Date.diff(deadline, Date.utc_today()) >= 0 and
      Date.diff(deadline, Date.utc_today()) <= @dispute_window_days
  end
end
```
