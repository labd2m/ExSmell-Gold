```elixir
defmodule Notifications.Dispatcher do
  @moduledoc """
  Dispatches notifications across multiple channels (email, SMS, push, webhook)
  with priority-aware routing and retry tracking.
  """

  alias Notifications.{Notification, EmailAdapter, SmsAdapter, PushAdapter, WebhookAdapter}
  alias Notifications.{DeliveryLog, RetryQueue}

  @max_retries 3
  @high_priority_threshold 8


  def dispatch(%Notification{
        channel: :email,
        priority: priority,
        recipient_id: recipient_id,
        payload: payload,
        metadata: metadata,
        retry_count: retry_count
      })
      when priority >= @high_priority_threshold and retry_count < @max_retries do
    case EmailAdapter.send_urgent(recipient_id, payload, metadata) do
      {:ok, message_id} ->
        DeliveryLog.record(recipient_id, :email, :delivered, message_id)
        {:ok, message_id}

      {:error, reason} ->
        RetryQueue.enqueue(:email, recipient_id, payload, retry_count + 1)
        {:error, reason}
    end
  end

  def dispatch(%Notification{
        channel: :email,
        priority: priority,
        recipient_id: recipient_id,
        payload: payload,
        metadata: metadata,
        retry_count: retry_count
      })
      when priority < @high_priority_threshold and retry_count < @max_retries do
    case EmailAdapter.send(recipient_id, payload, metadata) do
      {:ok, message_id} ->
        DeliveryLog.record(recipient_id, :email, :delivered, message_id)
        {:ok, message_id}

      {:error, reason} ->
        RetryQueue.enqueue(:email, recipient_id, payload, retry_count + 1)
        {:error, reason}
    end
  end

  def dispatch(%Notification{
        channel: :sms,
        priority: _priority,
        recipient_id: recipient_id,
        payload: payload,
        metadata: metadata,
        retry_count: retry_count
      })
      when retry_count < @max_retries do
    phone = Map.fetch!(metadata, :phone_number)

    case SmsAdapter.send(phone, payload) do
      {:ok, sid} ->
        DeliveryLog.record(recipient_id, :sms, :delivered, sid)
        {:ok, sid}

      {:error, reason} ->
        RetryQueue.enqueue(:sms, recipient_id, payload, retry_count + 1)
        {:error, reason}
    end
  end

  def dispatch(%Notification{
        channel: :push,
        priority: priority,
        recipient_id: recipient_id,
        payload: payload,
        metadata: metadata,
        retry_count: retry_count
      })
      when retry_count < @max_retries do
    device_token = Map.fetch!(metadata, :device_token)

    opts = if priority >= @high_priority_threshold, do: [urgent: true], else: []

    case PushAdapter.send(device_token, payload, opts) do
      {:ok, ref} ->
        DeliveryLog.record(recipient_id, :push, :delivered, ref)
        {:ok, ref}

      {:error, reason} ->
        RetryQueue.enqueue(:push, recipient_id, payload, retry_count + 1)
        {:error, reason}
    end
  end

  def dispatch(%Notification{
        channel: :webhook,
        priority: _priority,
        recipient_id: recipient_id,
        payload: payload,
        metadata: metadata,
        retry_count: retry_count
      })
      when retry_count < @max_retries do
    url = Map.fetch!(metadata, :webhook_url)

    case WebhookAdapter.post(url, payload) do
      {:ok, status} ->
        DeliveryLog.record(recipient_id, :webhook, :delivered, status)
        {:ok, status}

      {:error, reason} ->
        RetryQueue.enqueue(:webhook, recipient_id, payload, retry_count + 1)
        {:error, reason}
    end
  end


  def dispatch(%Notification{retry_count: retry_count, recipient_id: recipient_id})
      when retry_count >= @max_retries do
    DeliveryLog.record(recipient_id, :unknown, :exhausted, nil)
    {:error, :max_retries_exceeded}
  end
end
```
