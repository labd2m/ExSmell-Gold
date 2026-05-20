# Annotated Bad Example 45

## Metadata

- **Smell name**: Complex extractions in clauses
- **Expected smell location**: `Notifications.Dispatcher.dispatch/1` — all three clauses
- **Affected function(s)**: `dispatch/1`
- **Explanation**: The three clauses of `dispatch/1` all destructure `%Notification{}` in the function signature, extracting `channel` and `priority` to support the guards and `recipient_id`, `template`, `payload`, `scheduled_at`, and `notification_id` for use only inside the body. A reader scanning the clause heads cannot immediately distinguish which extractions are doing meaningful routing work from those that are just convenient data pulls, and the problem compounds as the number of clauses or struct fields grows.

## Code

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

  # VALIDATION: SMELL START - Complex extractions in clauses
  # VALIDATION: This is a smell because only `channel` and `priority` are needed
  # for the guard expressions. However, `recipient_id`, `template`, `payload`,
  # `scheduled_at`, and `notification_id` are also bound directly in the clause
  # signatures even though they are only referenced inside the function bodies.
  # Mixing these two categories of binding across all three clauses makes the
  # dispatch logic harder to follow.

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

  # VALIDATION: SMELL END

  defp render_template(template, payload) do
    Notifications.TemplateEngine.render(template, payload)
  end
end
```
