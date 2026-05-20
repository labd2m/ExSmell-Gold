```elixir
defmodule Notifications.DeliveryEngine do
  @moduledoc """
  Routes and delivers application notifications across email, SMS, and push channels.
  Applies per-channel content rendering, structured delivery logging, and rate control.
  """

  alias Notifications.{Template, RateLimiter, DeliveryLog}
  alias Notifications.Channel.{Email, SMS, Push}
  require Logger

  @sender_email "notifications@platform.example.com"
  @sender_phone "+18005550100"

  def process(%Notification{recipient_id: recipient_id} = notification) do
    case RateLimiter.allow?(recipient_id) do
      true ->
        deliver_notification(notification)

      false ->
        Logger.warning("Notification throttled for recipient=#{recipient_id}")
        {:error, :rate_limited}
    end
  end

  def deliver_notification(%Notification{
        channel: channel,
        priority: priority,
        recipient_id: recipient_id,
        recipient_email: recipient_email,
        template_id: template_id,
        locale: locale,
        payload: payload,
        scheduled_at: scheduled_at
      })
      when channel == :email and priority == :critical do
    template = Template.get!(template_id, locale)
    body = Template.render_html(template, payload)

    result =
      Email.send(%{
        to: recipient_email,
        from: @sender_email,
        subject: "[ACTION REQUIRED] #{template.title}",
        html_body: body
      })

    DeliveryLog.write(recipient_id, :email, :critical, scheduled_at, result)
    handle_result(result, recipient_id, :email)
  end

  def deliver_notification(%Notification{
        channel: channel,
        priority: priority,
        recipient_id: recipient_id,
        recipient_email: recipient_email,
        template_id: template_id,
        locale: locale,
        payload: payload,
        scheduled_at: scheduled_at
      })
      when channel == :email and priority in [:high, :normal] do
    template = Template.get!(template_id, locale)
    body = Template.render_html(template, payload)

    result =
      Email.send(%{
        to: recipient_email,
        from: @sender_email,
        subject: template.title,
        html_body: body
      })

    DeliveryLog.write(recipient_id, :email, priority, scheduled_at, result)
    handle_result(result, recipient_id, :email)
  end

  def deliver_notification(%Notification{
        channel: channel,
        priority: priority,
        recipient_id: recipient_id,
        recipient_phone: recipient_phone,
        template_id: template_id,
        locale: locale,
        payload: payload,
        scheduled_at: scheduled_at
      })
      when channel == :sms do
    template = Template.get!(template_id, locale)
    text = Template.render_sms(template, payload)

    result =
      SMS.send(%{
        to: recipient_phone,
        from: @sender_phone,
        body: text
      })

    DeliveryLog.write(recipient_id, :sms, priority, scheduled_at, result)
    handle_result(result, recipient_id, :sms)
  end

  def deliver_notification(%Notification{
        channel: channel,
        priority: priority,
        recipient_id: recipient_id,
        template_id: template_id,
        locale: locale,
        payload: payload,
        scheduled_at: scheduled_at
      })
      when channel == :push do
    template = Template.get!(template_id, locale)
    push_body = Template.render_push(template, payload)
    tokens = DeliveryLog.fetch_push_tokens(recipient_id)

    result =
      Push.broadcast(tokens, %{
        title: template.title,
        body: push_body,
        data: %{priority: priority}
      })

    DeliveryLog.write(recipient_id, :push, priority, scheduled_at, result)
    handle_result(result, recipient_id, :push)
  end


  def deliver_notification(%Notification{channel: channel, recipient_id: id}) do
    Logger.error("No delivery handler matched: channel=#{channel} recipient=#{id}")
    {:error, :unsupported_channel}
  end

  defp handle_result({:ok, _} = ok, _recipient_id, _channel), do: ok

  defp handle_result({:error, reason}, recipient_id, channel) do
    Logger.error(
      "Delivery failed: channel=#{channel} recipient=#{recipient_id} reason=#{inspect(reason)}"
    )

    {:error, reason}
  end
end
```
