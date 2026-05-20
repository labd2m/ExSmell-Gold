```elixir
defmodule Notifications.Dispatcher do
  alias Notifications.{Notification, Recipient, EmailAdapter, PushAdapter, SMSAdapter, DeliveryLog}
  require Logger

  @moduledoc """
  Routes notifications to the correct delivery adapter based on channel
  and priority. Supports email, push, and SMS delivery channels.
  """

  @high_priority_timeout_ms 3_000
  @standard_timeout_ms 10_000

  def dispatch_notification(%Notification{
        id: id,
        recipient_id: recipient_id,
        channel: channel,
        priority: priority,
        subject: subject,
        body: body,
        metadata: metadata
      })
      when channel == :email and priority == :high do
    Logger.info("Dispatching high-priority email notification #{id}")
    recipient = Recipient.get!(recipient_id)

    payload = %{
      to: recipient.email,
      subject: "[URGENT] #{subject}",
      body: body,
      notification_id: id,
      tracking: Map.get(metadata, :tracking_pixel, false)
    }

    case EmailAdapter.send(payload, timeout: @high_priority_timeout_ms) do
      {:ok, message_id} ->
        DeliveryLog.record_success(id, recipient_id, :email, message_id)
        {:ok, message_id}

      {:error, reason} ->
        Logger.error("High-priority email #{id} failed: #{inspect(reason)}")
        DeliveryLog.record_failure(id, recipient_id, :email, reason)
        {:error, reason}
    end
  end

  def dispatch_notification(%Notification{
        id: id,
        recipient_id: recipient_id,
        channel: channel,
        priority: priority,
        subject: subject,
        body: body,
        metadata: metadata
      })
      when channel == :push and priority in [:high, :normal] do
    Logger.info("Dispatching push notification #{id} (priority: #{priority})")
    recipient = Recipient.get!(recipient_id)
    device_tokens = Map.get(metadata, :device_tokens, [])
    badge_count = Map.get(metadata, :badge_count, 0)

    payload = %{
      tokens: device_tokens,
      title: subject,
      message: body,
      notification_id: id,
      badge: badge_count,
      sound: if(priority == :high, do: "urgent.aiff", else: "default")
    }

    case PushAdapter.send_bulk(recipient.push_credentials, payload) do
      {:ok, receipt} ->
        DeliveryLog.record_success(id, recipient_id, :push, receipt)
        {:ok, receipt}

      {:error, reason} ->
        Logger.error("Push notification #{id} failed: #{inspect(reason)}")
        DeliveryLog.record_failure(id, recipient_id, :push, reason)
        {:error, reason}
    end
  end

  def dispatch_notification(%Notification{
        id: id,
        recipient_id: recipient_id,
        channel: channel,
        priority: priority,
        subject: subject,
        body: body,
        metadata: metadata
      })
      when channel == :sms and priority == :high do
    Logger.info("Dispatching SMS notification #{id}")
    recipient = Recipient.get!(recipient_id)
    sender_id = Map.get(metadata, :sender_id, "SYSTEM")
    short_body = if String.length(body) > 160, do: String.slice(body, 0, 157) <> "...", else: body

    payload = %{
      to: recipient.phone_number,
      from: sender_id,
      message: "#{subject}: #{short_body}",
      notification_id: id
    }

    _ = priority

    case SMSAdapter.send(payload, timeout: @standard_timeout_ms) do
      {:ok, sms_id} ->
        DeliveryLog.record_success(id, recipient_id, :sms, sms_id)
        {:ok, sms_id}

      {:error, reason} ->
        Logger.error("SMS notification #{id} failed: #{inspect(reason)}")
        DeliveryLog.record_failure(id, recipient_id, :sms, reason)
        {:error, reason}
    end
  end
end
```
