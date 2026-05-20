```elixir
defmodule Notifications.Dispatcher do
  @moduledoc """
  Routes outbound notifications to the appropriate delivery backend
  based on channel type and message priority level.
  """

  alias Notifications.{
    Notification,
    PushGateway,
    EmailBackend,
    SMSGateway,
    DeliveryLog,
    RecipientStore
  }

  @urgent_priorities [:critical, :high]
  @retry_delay_seconds 30

  def dispatch(%Notification{
        channel: channel,
        priority: priority,
        recipient_id: recipient_id,
        template: template,
        payload: payload,
        scheduled_at: scheduled_at,
        notification_id: notification_id
      })
      when channel == :push and priority in @urgent_priorities do
    recipient = RecipientStore.get!(recipient_id)

    rendered = render_template(template, payload)

    result =
      PushGateway.send_urgent(%{
        device_token: recipient.device_token,
        title: rendered.title,
        body: rendered.body,
        notification_id: notification_id,
        metadata: %{scheduled_at: scheduled_at, priority: priority}
      })

    case result do
      {:ok, gateway_id} ->
        DeliveryLog.record(:push_delivered, %{
          notification_id: notification_id,
          recipient_id: recipient_id,
          gateway_id: gateway_id,
          channel: channel,
          priority: priority
        })
        {:ok, gateway_id}

      {:error, reason} ->
        DeliveryLog.record(:push_failed, %{
          notification_id: notification_id,
          recipient_id: recipient_id,
          reason: reason
        })
        {:retry, @retry_delay_seconds, reason}
    end
  end

  def dispatch(%Notification{
        channel: channel,
        priority: priority,
        recipient_id: recipient_id,
        template: template,
        payload: payload,
        scheduled_at: scheduled_at,
        notification_id: notification_id
      })
      when channel == :email do
    recipient = RecipientStore.get!(recipient_id)
    rendered = render_template(template, payload)
    deliver_at = scheduled_at || DateTime.utc_now()

    result =
      EmailBackend.enqueue(%{
        to: recipient.email,
        subject: rendered.subject,
        html_body: rendered.html_body,
        text_body: rendered.text_body,
        notification_id: notification_id,
        deliver_at: deliver_at
      })

    case result do
      {:ok, job_id} ->
        DeliveryLog.record(:email_enqueued, %{
          notification_id: notification_id,
          recipient_id: recipient_id,
          job_id: job_id,
          priority: priority,
          deliver_at: deliver_at
        })
        {:ok, {:scheduled, job_id}}

      {:error, reason} ->
        DeliveryLog.record(:email_enqueue_failed, %{
          notification_id: notification_id,
          recipient_id: recipient_id,
          reason: reason
        })
        {:error, reason}
    end
  end

  def dispatch(%Notification{
        channel: channel,
        priority: priority,
        recipient_id: recipient_id,
        template: template,
        payload: payload,
        scheduled_at: _scheduled_at,
        notification_id: notification_id
      })
      when channel == :sms and priority in @urgent_priorities do
    recipient = RecipientStore.get!(recipient_id)
    rendered = render_template(template, payload)

    result =
      SMSGateway.send(%{
        phone_number: recipient.phone_number,
        message: rendered.sms_body,
        notification_id: notification_id
      })

    case result do
      {:ok, message_sid} ->
        DeliveryLog.record(:sms_delivered, %{
          notification_id: notification_id,
          recipient_id: recipient_id,
          message_sid: message_sid
        })
        {:ok, message_sid}

      {:error, reason} ->
        DeliveryLog.record(:sms_failed, %{
          notification_id: notification_id,
          recipient_id: recipient_id,
          reason: reason
        })
        {:error, reason}
    end
  end


  defp render_template(template, payload) do
    Notifications.TemplateEngine.render(template, payload)
  end
end
```
