```elixir
defmodule Notifications.EventDispatcher do
  @moduledoc """
  Routes notification events to the appropriate delivery channel
  based on event type and priority level.
  """

  require Logger

  alias Notifications.{
    Channel,
    DeliveryLog,
    NotificationEvent,
    RecipientStore,
    TemplateRenderer
  }

  @critical_types [:security_alert, :payment_failed, :account_locked]
  @async_types [:newsletter, :digest, :promotion]

  def dispatch_all(events) when is_list(events) do
    Task.async_stream(events, &dispatch_event/1,
      max_concurrency: 10,
      on_timeout: :kill_task
    )
    |> Enum.reduce({[], []}, fn
      {:ok, {:ok, ref}}, {ok, err} -> {[ref | ok], err}
      {:ok, {:error, reason}}, {ok, err} -> {ok, [reason | err]}
      {:exit, _}, {ok, err} -> {ok, [:timeout | err]}
    end)
    |> then(fn {ok, err} -> {:ok, %{dispatched: length(ok), failed: length(err)}} end)
  end

  def dispatch_event(%NotificationEvent{
        type: type,
        priority: priority,
        recipient_id: recipient_id,
        channel: channel,
        payload: payload,
        ref: ref
      })
      when type in @critical_types and priority == :high do
    Logger.warning("[EventDispatcher] Critical event ref=#{ref} type=#{type} recipient=#{recipient_id}")

    with {:ok, recipient} <- RecipientStore.fetch(recipient_id),
         {:ok, body} <- TemplateRenderer.render(type, payload),
         :ok <- Channel.send_urgent(channel, recipient, body) do
      DeliveryLog.record(ref, type, recipient_id, :delivered, :urgent_path)
      {:ok, ref}
    else
      {:error, reason} ->
        DeliveryLog.record(ref, type, recipient_id, :failed, reason)
        {:error, reason}
    end
  end

  def dispatch_event(%NotificationEvent{
        type: type,
        priority: priority,
        recipient_id: recipient_id,
        channel: channel,
        payload: payload,
        ref: ref
      })
      when type not in @async_types and priority == :normal do
    Logger.info("[EventDispatcher] Standard event ref=#{ref} type=#{type} recipient=#{recipient_id}")

    with {:ok, recipient} <- RecipientStore.fetch(recipient_id),
         {:ok, body} <- TemplateRenderer.render(type, payload),
         :ok <- Channel.send(channel, recipient, body) do
      DeliveryLog.record(ref, type, recipient_id, :delivered, :standard_path)
      {:ok, ref}
    else
      {:error, reason} ->
        DeliveryLog.record(ref, type, recipient_id, :failed, reason)
        {:error, reason}
    end
  end

  def dispatch_event(%NotificationEvent{
        type: type,
        priority: priority,
        recipient_id: recipient_id,
        channel: channel,
        payload: payload,
        ref: ref
      })
      when type in @async_types and priority == :low do
    Logger.debug("[EventDispatcher] Async event ref=#{ref} type=#{type} recipient=#{recipient_id}")

    with {:ok, recipient} <- RecipientStore.fetch(recipient_id),
         {:ok, body} <- TemplateRenderer.render(type, payload),
         :ok <- Channel.enqueue(channel, recipient, body) do
      DeliveryLog.record(ref, type, recipient_id, :queued, :async_path)
      {:ok, ref}
    else
      {:error, reason} ->
        DeliveryLog.record(ref, type, recipient_id, :failed, reason)
        {:error, reason}
    end
  end

  def dispatch_event(%NotificationEvent{
        type: type,
        priority: priority,
        recipient_id: recipient_id,
        channel: _channel,
        payload: _payload,
        ref: ref
      })
      when priority == :suppressed do
    Logger.debug("[EventDispatcher] Suppressed event ref=#{ref} type=#{type} recipient=#{recipient_id}")
    DeliveryLog.record(ref, type, recipient_id, :suppressed, :suppression_policy)
    {:ok, ref}
  end

  def retry_failed(ref) do
    case DeliveryLog.fetch(ref) do
      {:ok, log_entry} ->
        Logger.info("[EventDispatcher] Retrying delivery ref=#{ref}")
        dispatch_event(log_entry.original_event)

      {:error, :not_found} ->
        {:error, :unknown_ref}
    end
  end
end
```
