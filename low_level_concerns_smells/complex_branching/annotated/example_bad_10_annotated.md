# Code Smell: Complex branching

- **Smell name:** Complex branching
- **Expected smell location:** `deliver_sms/3`, inside the `case` that handles all response variants from `SmsGatewayClient.send/2`
- **Affected function(s):** `deliver_sms/3`
- **Short explanation:** `deliver_sms/3` collapses every possible response from the SMS gateway — accepted, queued, invalid number, opt-out, carrier rejection, content filter block, daily limit exceeded, account suspended, and two transport-level failures — into a single `case` expression. Each clause performs distinct side-effects (retry scheduling, opt-out recording, quota tracking, audit logging). The function's cyclomatic complexity is very high; a crash in any one branch propagates without executing the side-effects of the others, and adding a new response code forces a developer to read the entire block.

```elixir
defmodule Notifications.SmsDeliveryAgent do
  @moduledoc """
  Delivers SMS notifications via an external gateway, handling all gateway
  response types and coordinating retry, opt-out, and quota side-effects.
  """

  alias Notifications.SmsGatewayClient
  alias Notifications.DeliveryLog
  alias Notifications.OptOutRegistry
  alias Notifications.RetryQueue
  alias Notifications.QuotaTracker
  alias Notifications.AuditLogger

  @max_message_length 160
  @retry_delay_seconds 60

  def send_notification(recipient_id, phone_number, message, opts \\ []) do
    sender_id = Keyword.get(opts, :sender_id, "MYAPP")
    priority  = Keyword.get(opts, :priority, :normal)

    truncated = String.slice(message, 0, @max_message_length)

    payload = %{
      to:        phone_number,
      from:      sender_id,
      body:      truncated,
      priority:  priority,
      recipient: recipient_id
    }

    with {:ok, delivery} <- deliver_sms(recipient_id, payload, opts),
         :ok <- DeliveryLog.record(recipient_id, delivery) do
      {:ok, delivery}
    end
  end

  # VALIDATION: SMELL START - Complex branching
  # VALIDATION: This is a smell because `deliver_sms/3` fuses all possible
  # SMS gateway response variants into one `case` block. Nine status paths
  # plus two error patterns — each with their own side-effects such as
  # scheduling retries, recording opt-outs, tracking quota, and writing
  # audit entries — are all handled in a single function. The cyclomatic
  # complexity is very high, making the function hard to read, hard to test
  # per branch in isolation, and brittle: any runtime exception thrown by a
  # side-effect call (e.g., `OptOutRegistry.record/2`) will prevent the
  # correct response from being returned, and the resulting error will not
  # clearly identify which response variant caused the problem.
  defp deliver_sms(recipient_id, payload, opts) do
    case SmsGatewayClient.send(payload, opts) do
      {:ok, %{status: "accepted", message_id: mid, queued_at: ts}} ->
        {:ok, %{message_id: mid, status: :accepted, queued_at: ts}}

      {:ok, %{status: "queued", message_id: mid, estimated_delivery: eta}} ->
        RetryQueue.monitor(mid, eta)
        {:ok, %{message_id: mid, status: :queued, estimated_delivery: eta}}

      {:ok, %{status: "failed", reason: "invalid_number", number: num}} ->
        AuditLogger.log(:invalid_sms_number, recipient_id, %{number: num})
        {:error, {:invalid_number, num}}

      {:ok, %{status: "failed", reason: "opt_out", number: num}} ->
        OptOutRegistry.record(recipient_id, num)
        {:error, :recipient_opted_out}

      {:ok, %{status: "failed", reason: "carrier_rejection", carrier: carrier, code: code}} ->
        AuditLogger.log(:carrier_rejection, recipient_id, %{carrier: carrier, code: code})
        RetryQueue.schedule(payload, @retry_delay_seconds)
        {:error, {:carrier_rejection, carrier}}

      {:ok, %{status: "failed", reason: "content_filtered", filter_id: fid}} ->
        AuditLogger.log(:sms_content_filtered, recipient_id, %{filter_id: fid})
        {:error, {:content_filtered, fid}}

      {:ok, %{status: "failed", reason: "daily_limit_exceeded", resets_at: resets}} ->
        QuotaTracker.record_exhaustion(:sms, recipient_id, resets)
        {:error, {:daily_limit_exceeded, resets}}

      {:ok, %{status: "failed", reason: "account_suspended"}} ->
        AuditLogger.log(:sms_account_suspended, recipient_id, %{})
        {:error, :sms_account_suspended}

      {:ok, %{status: "failed", reason: other}} ->
        AuditLogger.log(:sms_unknown_failure, recipient_id, %{reason: other})
        {:error, {:sms_delivery_failed, other}}

      {:error, %{reason: :timeout}} ->
        RetryQueue.schedule(payload, @retry_delay_seconds)
        {:error, :gateway_timeout}

      {:error, reason} ->
        AuditLogger.log(:sms_gateway_error, recipient_id, %{reason: reason})
        {:error, :gateway_error}
    end
  end
  # VALIDATION: SMELL END

  defp build_delivery_ref(message_id) do
    "sms-#{message_id}-#{System.system_time(:millisecond)}"
  end
end
```
