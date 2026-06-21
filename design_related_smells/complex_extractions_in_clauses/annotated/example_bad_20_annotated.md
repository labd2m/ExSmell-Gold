# Annotated Example — Bad Code

- **Smell name:** Complex extractions in clauses
- **Expected smell location:** `dispatch/1` function, multi-clause heads
- **Affected function(s):** `dispatch/1`
- **Short explanation:** Every clause head pulls `channel`, `priority`, `recipient_id`, `payload`, `metadata`, and `retry_count` from `%Notification{}`. Only `channel` is matched by value and `priority` and `retry_count` are used in guards; the other three fields (`recipient_id`, `payload`, `metadata`) are only used in the body. The overloaded clause signatures hide the actual dispatch logic.

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

  # VALIDATION: SMELL START - Complex extractions in clauses
  # VALIDATION: This is a smell because `recipient_id`, `payload`, and `metadata`
  # are extracted in each clause head despite having no role in pattern matching
  # or guard evaluation. Only `channel` (matched literally), `priority` and
  # `retry_count` (used in guards) govern which clause fires. Mixing guard-driving
  # fields with body-only fields in every clause head inflates signatures and
  # makes the dispatch rules harder to scan.

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

  # VALIDATION: SMELL END

  def dispatch(%Notification{retry_count: retry_count, recipient_id: recipient_id})
      when retry_count >= @max_retries do
    DeliveryLog.record(recipient_id, :unknown, :exhausted, nil)
    {:error, :max_retries_exceeded}
  end
end
```
