# Code Smell: Complex branching

- **Smell name:** Complex branching
- **Expected smell location:** `handle_transfer_response/3`, inside the `case` that handles all response variants from `OpenBankingClient.initiate_transfer/2`
- **Affected function(s):** `handle_transfer_response/3`
- **Short explanation:** `handle_transfer_response/3` maps every possible outcome of an open-banking transfer API call — accepted, pending bank authorisation, insufficient funds, beneficiary account invalid, daily transfer limit exceeded, currency not supported, bank connectivity error, duplicate transaction, fraud hold, and two transport-level failures — into a single `case` block. Each branch triggers distinct side-effects: ledger writes, fraud holds, limit tracking, retry scheduling, and audit logging. The very high cyclomatic complexity makes the function hard to test per branch in isolation and fragile: a runtime exception thrown by any one branch's side-effect (e.g., `FraudHoldRegistry.open/3`) produces an opaque error with no indication of which bank response triggered it.

```elixir
defmodule Payments.BankTransferHandler do
  @moduledoc """
  Initiates and tracks outbound bank transfers through an open-banking
  provider, applying all transfer response types to internal ledger and
  compliance state.
  """

  alias Payments.OpenBankingClient
  alias Payments.TransferLedger
  alias Payments.FraudHoldRegistry
  alias Payments.DailyLimitTracker
  alias Payments.RetryScheduler
  alias Notifications.EmailDispatcher
  alias Payments.AuditLogger

  @retry_delay_seconds 180
  @fraud_hold_review_hours 24

  def execute_transfer(transfer_id, account_id, transfer_params, operator_id) do
    with {:ok, transfer} <- build_transfer(transfer_id, account_id, transfer_params),
         :ok <- TransferLedger.reserve(account_id, transfer.amount_cents),
         {:ok, result} <- handle_transfer_response(transfer, account_id, operator_id),
         :ok <- TransferLedger.record(account_id, transfer, result) do
      {:ok, result}
    else
      {:error, reason} = err ->
        TransferLedger.release_reservation(account_id, transfer_id)
        err
    end
  end

  # VALIDATION: SMELL START - Complex branching
  # VALIDATION: This is a smell because `handle_transfer_response/3` fuses
  # every possible response from `OpenBankingClient.initiate_transfer/2`
  # into a single `case` block with eleven branches. Each branch — accepted,
  # pending authorisation, insufficient funds, invalid beneficiary, daily
  # limit exceeded, unsupported currency, bank unreachable, duplicate
  # transaction, fraud hold, transport timeout, and generic error — has its
  # own business logic and side-effects. The cyclomatic complexity is very
  # high; a developer adding a new open-banking response code must read the
  # entire block to avoid introducing interference, and a crash inside any
  # one branch (e.g., `FraudHoldRegistry.open/3` failing) surfaces as a
  # generic error that hides which transfer response was being processed.
  defp handle_transfer_response(transfer, account_id, operator_id) do
    case OpenBankingClient.initiate_transfer(transfer, %{operator_id: operator_id}) do
      {:ok, %{status: "accepted", transfer_ref: ref, settled_at: ts, net_amount: net}} ->
        AuditLogger.log(:transfer_accepted, account_id, %{ref: ref, net: net})
        EmailDispatcher.send_transfer_confirmation(transfer.beneficiary_email, ref, net)
        {:ok, %{status: :accepted, transfer_ref: ref, settled_at: ts, net_amount: net}}

      {:ok, %{status: "pending_authorisation", auth_url: url, expires_at: exp}} ->
        AuditLogger.log(:transfer_pending_auth, account_id, %{transfer_id: transfer.id})
        EmailDispatcher.send_authorisation_request(transfer.owner_email, url, exp)
        {:ok, %{status: :pending_authorisation, auth_url: url, expires_at: exp}}

      {:ok, %{status: "failed", reason: "insufficient_funds", available_cents: avail}} ->
        TransferLedger.release_reservation(account_id, transfer.id)
        AuditLogger.log(:transfer_insufficient_funds, account_id, %{available: avail, requested: transfer.amount_cents})
        {:error, {:insufficient_funds, avail}}

      {:ok, %{status: "failed", reason: "invalid_beneficiary", field: field, detail: detail}} ->
        AuditLogger.log(:invalid_beneficiary, account_id, %{field: field, detail: detail})
        {:error, {:invalid_beneficiary, %{field: field, detail: detail}}}

      {:ok, %{status: "failed", reason: "daily_limit_exceeded", limit_cents: lim, resets_at: resets}} ->
        DailyLimitTracker.record_breach(account_id, lim, resets)
        AuditLogger.log(:daily_limit_exceeded, account_id, %{limit: lim, resets_at: resets})
        {:error, {:daily_limit_exceeded, %{limit_cents: lim, resets_at: resets}}}

      {:ok, %{status: "failed", reason: "currency_not_supported", currency: cur}} ->
        {:error, {:currency_not_supported, cur}}

      {:ok, %{status: "failed", reason: "bank_unreachable", bank_id: bid, retry_after: secs}} ->
        RetryScheduler.schedule(transfer.id, secs, operator_id)
        AuditLogger.log(:bank_unreachable, account_id, %{bank_id: bid})
        {:error, {:bank_unreachable, bid}}

      {:ok, %{status: "failed", reason: "duplicate_transaction", original_ref: orig}} ->
        AuditLogger.log(:duplicate_transfer, account_id, %{original_ref: orig, transfer_id: transfer.id})
        {:error, {:duplicate_transaction, orig}}

      {:ok, %{status: "failed", reason: "fraud_hold", hold_id: hid, review_by: rev}} ->
        FraudHoldRegistry.open(account_id, hid, %{transfer_id: transfer.id, review_by: rev})
        AuditLogger.log(:transfer_fraud_hold, account_id, %{hold_id: hid, review_by: rev})
        EmailDispatcher.send_fraud_hold_notice(transfer.owner_email, hid, @fraud_hold_review_hours)
        {:error, {:fraud_hold, hid}}

      {:ok, %{status: "failed", reason: other}} ->
        AuditLogger.log(:transfer_unknown_failure, account_id, %{reason: other, transfer_id: transfer.id})
        {:error, {:transfer_failed, other}}

      {:error, %{reason: :timeout}} ->
        RetryScheduler.schedule(transfer.id, @retry_delay_seconds, operator_id)
        {:error, :open_banking_timeout}

      {:error, reason} ->
        AuditLogger.log(:open_banking_error, account_id, %{reason: reason, transfer_id: transfer.id})
        {:error, :open_banking_error}
    end
  end
  # VALIDATION: SMELL END

  defp build_transfer(transfer_id, account_id, params) do
    {:ok,
     %{
       id: transfer_id,
       account_id: account_id,
       amount_cents: Map.fetch!(params, :amount_cents),
       currency: Map.get(params, :currency, "BRL"),
       beneficiary_email: Map.fetch!(params, :beneficiary_email),
       owner_email: Map.fetch!(params, :owner_email),
       reference: Map.get(params, :reference, ""),
       initiated_at: DateTime.utc_now()
     }}
  end
end
```
