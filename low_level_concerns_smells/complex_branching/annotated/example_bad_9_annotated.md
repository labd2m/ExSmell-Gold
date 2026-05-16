# Code Smell: Complex branching

- **Smell name:** Complex branching
- **Expected smell location:** `execute_charge/3`, inside the `case` that handles all response variants from `PaymentGatewayClient.charge/2`
- **Affected function(s):** `execute_charge/3`
- **Short explanation:** `execute_charge/3` handles every possible outcome of a payment gateway call — success, insufficient funds, stolen card, expired card, do-not-honour, processing error, currency mismatch, duplicate charge, and two network-level failures — inside one monolithic `case` block. Each branch carries distinct side-effects (audit logging, fraud flagging, ledger writes). The resulting function has very high cyclomatic complexity; a single misplaced pattern or exception in any clause can corrupt the handling of all other responses.

```elixir
defmodule Billing.ChargeExecutor do
  @moduledoc """
  Executes payment charges via the payment gateway, handling all
  response types and orchestrating post-charge side-effects.
  """

  alias Billing.PaymentGatewayClient
  alias Billing.LedgerWriter
  alias Billing.FraudRegistry
  alias Billing.AuditLogger
  alias Notifications.EmailDispatcher

  @retry_wait_ms 2_000
  @currency_mismatch_threshold 0.01

  def charge_customer(account_id, amount_cents, payment_method, opts \\ []) do
    idempotency_key = Keyword.get(opts, :idempotency_key, generate_key(account_id))
    description     = Keyword.get(opts, :description, "Service charge")

    payload = %{
      amount:          amount_cents,
      currency:        "USD",
      payment_method:  payment_method,
      idempotency_key: idempotency_key,
      description:     description,
      metadata:        %{account_id: account_id}
    }

    with {:ok, charge} <- execute_charge(account_id, payload, opts),
         :ok <- LedgerWriter.record_charge(account_id, charge),
         :ok <- EmailDispatcher.send_receipt(account_id, charge) do
      {:ok, charge}
    end
  end

  # VALIDATION: SMELL START - Complex branching
  # VALIDATION: This is a smell because `execute_charge/3` concentrates the
  # handling of every response variant returned by `PaymentGatewayClient.charge/2`
  # in a single `case` block. Ten distinct branches — successful charge,
  # insufficient funds, stolen card, expired card, do-not-honour, processing
  # error, currency mismatch, duplicate charge, gateway timeout, and service
  # unavailability — each carry their own logic and side-effects. The cyclomatic
  # complexity is very high. Any exception thrown in one branch (e.g., a crash
  # inside `FraudRegistry.flag/2`) propagates upward without executing other
  # branches' cleanup, and a future maintainer adding a new response type must
  # navigate and understand the entire block before making a safe change.
  defp execute_charge(account_id, payload, opts) do
    case PaymentGatewayClient.charge(payload, opts) do
      {:ok, %{status: "succeeded", charge_id: id, amount: amt, captured_at: ts}} ->
        {:ok, %{charge_id: id, amount: amt, captured_at: ts, status: :succeeded}}

      {:ok, %{status: "failed", decline_code: "insufficient_funds"}} ->
        AuditLogger.log(:charge_declined, account_id, %{reason: :insufficient_funds})
        {:error, :insufficient_funds}

      {:ok, %{status: "failed", decline_code: "stolen_card", card_fingerprint: fp}} ->
        FraudRegistry.flag(account_id, %{reason: :stolen_card, fingerprint: fp})
        AuditLogger.log(:fraud_flag, account_id, %{reason: :stolen_card, fingerprint: fp})
        {:error, :stolen_card}

      {:ok, %{status: "failed", decline_code: "expired_card"}} ->
        {:error, :expired_card}

      {:ok, %{status: "failed", decline_code: "do_not_honour"}} ->
        AuditLogger.log(:charge_declined, account_id, %{reason: :do_not_honour})
        {:error, :do_not_honour}

      {:ok, %{status: "failed", decline_code: "processing_error", gateway_ref: ref}} ->
        AuditLogger.log(:gateway_processing_error, account_id, %{gateway_ref: ref})
        {:error, {:processing_error, ref}}

      {:ok, %{status: "failed", decline_code: "currency_not_supported", currency: cur}} ->
        {:error, {:currency_not_supported, cur}}

      {:ok, %{status: "failed", decline_code: "duplicate_transaction", original_charge_id: orig}} ->
        AuditLogger.log(:duplicate_charge_attempt, account_id, %{original_charge_id: orig})
        {:error, {:duplicate_transaction, orig}}

      {:ok, %{status: "failed", decline_code: other_code}} ->
        AuditLogger.log(:charge_declined, account_id, %{reason: other_code})
        {:error, {:charge_declined, other_code}}

      {:error, %{reason: :timeout}} ->
        Process.sleep(@retry_wait_ms)
        {:error, :gateway_timeout}

      {:error, %{reason: :unavailable, retry_after: secs}} ->
        {:error, {:gateway_unavailable, secs}}

      {:error, reason} ->
        AuditLogger.log(:gateway_error, account_id, %{reason: reason})
        {:error, :gateway_error}
    end
  end
  # VALIDATION: SMELL END

  defp generate_key(account_id) do
    :crypto.strong_rand_bytes(16)
    |> Base.encode16(case: :lower)
    |> then(&"#{account_id}-#{&1}")
  end
end
```
