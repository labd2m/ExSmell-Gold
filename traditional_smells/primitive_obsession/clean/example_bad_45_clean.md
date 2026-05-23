```elixir
defmodule Notifications.Dispatcher do
  @moduledoc """
  Routes and dispatches user notifications across multiple channels
  (email, SMS, push) with priority-based retry logic.
  """

  require Logger
  alias Notifications.{EmailAdapter, SmsAdapter, PushAdapter, AuditLog}

  @valid_channels ["email", "sms", "push", "webhook"]
  @valid_priorities ["critical", "high", "medium", "low"]
  @max_retries 5
  @retry_backoff_seconds %{"critical" => 10, "high" => 30, "medium" => 120, "low" => 600}

  @spec dispatch(String.t(), String.t(), String.t(), map(), integer()) ::
          {:ok, String.t()} | {:error, String.t()}
  def dispatch(recipient_id, channel, priority, payload, attempt \\ 1)
      when is_binary(recipient_id) and is_binary(channel) and
             is_binary(priority) and is_map(payload) and is_integer(attempt) do
    with :ok <- validate_channel(channel),
         :ok <- validate_priority(priority),
         :ok <- validate_payload(payload) do
      notification_id = generate_notification_id()

      record = build_notification_record(
        notification_id, recipient_id, channel, priority, payload
      )

      result =
        case channel do
          "email" -> EmailAdapter.send(recipient_id, payload)
          "sms" -> SmsAdapter.send(recipient_id, payload)
          "push" -> PushAdapter.send(recipient_id, payload)
          "webhook" -> dispatch_webhook(recipient_id, payload)
        end

      case result do
        {:ok, _} ->
          AuditLog.record_success(record)
          log_delivery_attempt(notification_id, channel, :success)
          {:ok, notification_id}

        {:error, reason} when attempt < @max_retries ->
          Logger.warning("Dispatch failed (#{reason}), scheduling retry #{attempt + 1}")
          schedule_retry(notification_id, recipient_id, channel, priority, payload, attempt)
          {:ok, notification_id}

        {:error, reason} ->
          AuditLog.record_failure(record, reason)
          log_delivery_attempt(notification_id, channel, :failure)
          {:error, "max_retries_exceeded"}
      end
    end
  end

  def dispatch(_, _, _, _, _), do: {:error, "invalid_arguments"}

  @spec schedule_retry(String.t(), String.t(), String.t(), String.t(), map(), integer()) :: :ok
  def schedule_retry(notification_id, recipient_id, channel, priority, payload, attempt)
      when is_binary(channel) and is_binary(priority) and is_integer(attempt) do
    delay = Map.get(@retry_backoff_seconds, priority, 120) * attempt

    Logger.info(
      "Scheduling retry for #{notification_id} via #{channel} in #{delay}s (attempt #{attempt + 1})"
    )

    Process.send_after(
      self(),
      {:retry_dispatch, recipient_id, channel, priority, payload, attempt + 1},
      delay * 1_000
    )

    :ok
  end

  @spec build_notification_record(String.t(), String.t(), String.t(), String.t(), map()) :: map()
  defp build_notification_record(notification_id, recipient_id, channel, priority, payload) do
    %{
      id: notification_id,
      recipient_id: recipient_id,
      channel: channel,
      priority: priority,
      payload: payload,
      created_at: DateTime.utc_now()
    }
  end

  defp log_delivery_attempt(notification_id, channel, status) do
    Logger.info("Notification #{notification_id} via #{channel}: #{status}")
  end

  defp dispatch_webhook(recipient_id, payload) do
    Logger.debug("Dispatching webhook for #{recipient_id}")
    {:ok, :webhook_dispatched}
  end

  defp validate_channel(channel) when channel in @valid_channels, do: :ok
  defp validate_channel(ch), do: {:error, "unsupported_channel: #{ch}"}

  defp validate_priority(priority) when priority in @valid_priorities, do: :ok
  defp validate_priority(p), do: {:error, "unknown_priority: #{p}"}

  defp validate_payload(%{"message" => msg}) when is_binary(msg) and byte_size(msg) > 0, do: :ok
  defp validate_payload(_), do: {:error, "payload_missing_message"}

  defp generate_notification_id do
    "NOTIF-" <> Base.encode16(:crypto.strong_rand_bytes(6))
  end
end
```
