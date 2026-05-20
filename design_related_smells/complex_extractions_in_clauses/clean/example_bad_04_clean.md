```elixir
defmodule Notifications.Dispatcher do
  @moduledoc """
  Routes outbound notifications to the correct delivery channel.
  Supports email, SMS, and push channels with per-channel retry
  and priority handling.
  """

  require Logger

  alias Notifications.{
    EmailAdapter,
    SmsAdapter,
    PushAdapter,
    RateLimiter,
    DeliveryLog,
    TemplateRenderer
  }

  @high_priority_levels [:critical, :urgent]

  def dispatch(%Notifications.Notification{
        notification_id: notification_id,
        recipient: recipient,
        subject: subject,
        body: body,
        metadata: metadata,
        channel: :email,
        priority: priority
      })
      when priority in @high_priority_levels do
    Logger.info("[Dispatcher] Sending high-priority email #{notification_id} to #{recipient}")

    rendered = TemplateRenderer.render(:email_high_priority, %{
      recipient: recipient,
      subject: subject,
      body: body,
      metadata: metadata
    })

    with :ok <- RateLimiter.check(:email, recipient, :high),
         {:ok, message_id} <- EmailAdapter.send_immediate(%{
           to: recipient,
           subject: subject,
           html_body: rendered,
           headers: %{"X-Priority" => "1", "X-Notification-Id" => notification_id}
         }),
         :ok <- DeliveryLog.record(notification_id, :email, :sent, %{message_id: message_id}) do
      Logger.debug("[Dispatcher] Email #{notification_id} delivered as #{message_id}")
      {:ok, :email, message_id}
    else
      {:error, :rate_limited} ->
        Logger.warning("[Dispatcher] Rate-limited on high-priority email to #{recipient}")
        DeliveryLog.record(notification_id, :email, :rate_limited, %{})
        {:error, :rate_limited}

      {:error, reason} ->
        Logger.error("[Dispatcher] Email dispatch failed for #{notification_id}: #{inspect(reason)}")
        DeliveryLog.record(notification_id, :email, :failed, %{reason: reason})
        {:error, reason}
    end
  end

  def dispatch(%Notifications.Notification{
        notification_id: notification_id,
        recipient: recipient,
        subject: subject,
        body: body,
        metadata: metadata,
        channel: :sms,
        priority: priority
      })
      when priority in @high_priority_levels do
    Logger.info("[Dispatcher] Sending high-priority SMS #{notification_id} to #{recipient}")

    sms_body = TemplateRenderer.render(:sms, %{subject: subject, body: body})
    truncated_body = String.slice(sms_body, 0, 160)

    with :ok <- RateLimiter.check(:sms, recipient, :high),
         {:ok, sid} <- SmsAdapter.send(%{
           to: recipient,
           body: truncated_body,
           tags: Map.get(metadata, :tags, []),
           idempotency_key: notification_id
         }),
         :ok <- DeliveryLog.record(notification_id, :sms, :sent, %{sid: sid}) do
      {:ok, :sms, sid}
    else
      {:error, :rate_limited} ->
        DeliveryLog.record(notification_id, :sms, :rate_limited, %{})
        {:error, :rate_limited}

      {:error, reason} ->
        Logger.error("[Dispatcher] SMS dispatch failed for #{notification_id}: #{inspect(reason)}")
        DeliveryLog.record(notification_id, :sms, :failed, %{reason: reason})
        {:error, reason}
    end
  end

  def dispatch(%Notifications.Notification{
        notification_id: notification_id,
        recipient: recipient,
        subject: subject,
        body: body,
        metadata: metadata,
        channel: :push,
        priority: priority
      })
      when priority in @high_priority_levels do
    Logger.info("[Dispatcher] Sending high-priority push #{notification_id} to #{recipient}")

    device_token = Map.fetch!(metadata, :device_token)
    platform = Map.get(metadata, :platform, :apns)

    payload = TemplateRenderer.render(:push, %{subject: subject, body: body})

    with :ok <- RateLimiter.check(:push, recipient, :high),
         {:ok, push_id} <- PushAdapter.send(%{
           device_token: device_token,
           platform: platform,
           title: subject,
           body: payload,
           data: %{notification_id: notification_id}
         }),
         :ok <- DeliveryLog.record(notification_id, :push, :sent, %{push_id: push_id}) do
      {:ok, :push, push_id}
    else
      {:error, reason} ->
        Logger.error("[Dispatcher] Push dispatch failed for #{notification_id}: #{inspect(reason)}")
        DeliveryLog.record(notification_id, :push, :failed, %{reason: reason})
        {:error, reason}
    end
  end

  def dispatch(%Notifications.Notification{notification_id: nid, channel: channel, priority: p})
      when p not in @high_priority_levels do
    Logger.debug("[Dispatcher] Queuing normal-priority #{channel} notification #{nid}")
    Notifications.Queue.enqueue(nid, channel, :normal)
    {:ok, :queued}
  end

  def dispatch(%Notifications.Notification{notification_id: nid, channel: unknown}) do
    Logger.error("[Dispatcher] Unknown channel '#{unknown}' for notification #{nid}")
    {:error, :unknown_channel}
  end
end
```
