```elixir
defmodule Payments.ChargebackHandler do
  @moduledoc """
  Processes incoming chargeback disputes from card networks.
  Classifies dispute risk, updates reserve balances, and queues
  cases for manual or automated resolution.
  """

  require Logger

  alias Payments.{Dispute, Account, Transaction, ReserveBalance, DisputeCase}
  alias Payments.Evidence
  alias Repo

  @auto_accept_threshold_cents 1_500
  @high_risk_reason_codes ["4853", "4855", "4863", "10.4", "UA02"]
  @evidence_window_days 7

  def handle(dispute_id, event_type) do
    with {:ok, dispute} <- Dispute.fetch(dispute_id),
         {:ok, txn} <- Transaction.fetch(dispute.transaction_id),
         {:ok, account} <- Account.fetch(txn.account_id) do
      process(dispute, txn, account, event_type)
    end
  end

  defp process(dispute, txn, account, :opened) do
    risk_level = assess_dispute_risk(dispute, account)

    days_to_respond = Evidence.response_deadline_days(dispute.card_network)
    deadline = Date.add(DateTime.to_date(dispute.raised_at), days_to_respond)

    reserve_impact =
      if account.reserve_balance_cents < dispute.amount_cents do
        Logger.warning("Account #{account.id} reserve insufficient for dispute #{dispute.id}")
        account.reserve_balance_cents
      else
        dispute.amount_cents
      end

    Repo.transaction(fn ->
      {:ok, _} =
        %ReserveBalance{
          account_id: account.id,
          delta_cents: -reserve_impact,
          reason: :chargeback_hold,
          reference_id: dispute.id,
          recorded_at: DateTime.utc_now()
        }
        |> Repo.insert()

      {:ok, dispute_case} =
        %DisputeCase{
          dispute_id: dispute.id,
          account_id: account.id,
          transaction_id: txn.id,
          amount_cents: dispute.amount_cents,
          reason_code: dispute.reason_code,
          card_network: dispute.card_network,
          risk_level: risk_level,
          response_deadline: deadline,
          status: route_case(risk_level, dispute.amount_cents),
          opened_at: DateTime.utc_now()
        }
        |> Repo.insert()

      dispute_case
    end)
    |> case do
      {:ok, dc} ->
        Logger.info("Dispute case #{dc.id} opened with risk #{risk_level}")
        maybe_auto_respond(dc, dispute, txn)
        {:ok, dc}

      {:error, reason} ->
        Logger.error("Failed to open dispute case #{dispute.id}: #{inspect(reason)}")
        {:error, :processing_failed}
    end
  end

  defp process(dispute, _txn, _account, :withdrawn) do
    Dispute.mark_withdrawn(dispute)
  end

  defp assess_dispute_risk(dispute, account) do
    reason_high_risk = dispute.reason_code in @high_risk_reason_codes
    account_high_risk = account.high_risk
    rate_exceeded = account.chargeback_rate > account.dispute_threshold

    cond do
      reason_high_risk and account_high_risk -> :critical
      reason_high_risk or (account_high_risk and rate_exceeded) -> :high
      rate_exceeded -> :medium
      true -> :low
    end
  end

  defp route_case(:critical, _amount), do: :manual_review
  defp route_case(:high, _amount), do: :manual_review

  defp route_case(_risk, amount) when amount <= @auto_accept_threshold_cents,
    do: :auto_accept

  defp route_case(_risk, _amount), do: :manual_review

  defp maybe_auto_respond(%DisputeCase{status: :auto_accept} = dc, dispute, txn) do
    evidence = Evidence.build_auto_response(dispute, txn)
    Evidence.submit(dispute.card_network, dispute.id, evidence)
    Logger.info("Auto-response submitted for dispute case #{dc.id}")
  end

  defp maybe_auto_respond(%DisputeCase{} = dc, _dispute, _txn) do
    Logger.info("Dispute case #{dc.id} queued for manual review")
    :ok
  end

  def list_open_cases(account_id) do
    DisputeCase
    |> DisputeCase.open_for_account_query(account_id)
    |> Repo.all()
  end

  def mark_resolved(%DisputeCase{} = dc, outcome) do
    dc
    |> DisputeCase.changeset(%{status: :resolved, outcome: outcome, resolved_at: DateTime.utc_now()})
    |> Repo.update()
  end
end
```
