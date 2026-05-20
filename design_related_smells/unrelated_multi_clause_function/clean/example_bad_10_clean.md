```elixir
defmodule NotificationDispatcher do
  @moduledoc """
  Central dispatcher for all outbound notifications in the platform.
  Supports push notifications, email alerts, and SMS-based verifications.
  """

  alias NotificationDispatcher.{PushNotification, EmailAlert, SmsVerification}
  alias NotificationDispatcher.{APNSClient, FCMClient, SMTPClient, TwilioClient}
  alias NotificationDispatcher.DeviceRegistry

  require Logger

  @doc """
  Dispatch a notification to the appropriate channel.

  Accepts a `%PushNotification{}`, `%EmailAlert{}`, or `%SmsVerification{}`
  and routes it to the correct provider.

  ## Examples

      iex> NotificationDispatcher.dispatch(%PushNotification{user_id: 1, body: "Hello"})
      {:ok, :sent}

  """

  def dispatch(%PushNotification{user_id: user_id, title: title, body: body} = notif) do
    with {:ok, devices} <- DeviceRegistry.list_active_devices(user_id),
         true <- Enum.any?(devices) do
      results =
        Enum.map(devices, fn device ->
          payload = build_push_payload(device.platform, title, body, notif.data)

          case device.platform do
            :ios -> APNSClient.send(device.token, payload)
            :android -> FCMClient.send(device.token, payload)
          end
        end)

      if Enum.any?(results, &match?({:ok, _}, &1)) do
        Logger.info("Push sent to user #{user_id}")
        {:ok, :sent}
      else
        {:error, :all_devices_failed}
      end
    else
      false -> {:error, :no_active_devices}
      error -> error
    end
  end

  # dispatch transactional email alert
  def dispatch(%EmailAlert{
        to: to,
        subject: subject,
        template: template,
        assigns: assigns
      }) do
    body_html = render_email_template(template, assigns)

    message = %{
      from: Application.fetch_env!(:app, :mailer_from),
      to: to,
      subject: subject,
      html_body: body_html,
      text_body: html_to_text(body_html)
    }

    case SMTPClient.deliver(message) do
      {:ok, _id} ->
        Logger.info("Email dispatched to #{to}")
        {:ok, :sent}

      {:error, reason} ->
        Logger.error("Email failed to #{to}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  # dispatch sms one-time password for phone verification
  def dispatch(%SmsVerification{phone: phone, otp: otp, locale: locale}) do
    message_body = localize_sms_body(locale, otp)

    case TwilioClient.send_sms(phone, message_body) do
      {:ok, sid} ->
        Logger.info("SMS OTP sent to #{phone}, SID=#{sid}")
        {:ok, :sent}

      {:error, :invalid_number} ->
        {:error, :invalid_phone_number}

      {:error, reason} ->
        Logger.warning("SMS failed to #{phone}: #{inspect(reason)}")
        {:error, reason}
    end
  end


  ## Private helpers

  defp build_push_payload(:ios, title, body, data) do
    %{aps: %{alert: %{title: title, body: body}, sound: "default"}, data: data}
  end

  defp build_push_payload(:android, title, body, data) do
    %{notification: %{title: title, body: body}, data: data}
  end

  defp render_email_template(template, assigns) do
    Phoenix.View.render_to_string(MyAppWeb.EmailView, "#{template}.html", assigns)
  end

  defp html_to_text(html), do: HtmlSanitizeEx.strip_tags(html)

  defp localize_sms_body("pt", otp), do: "Seu código de verificação é: #{otp}"
  defp localize_sms_body("es", otp), do: "Tu código de verificación es: #{otp}"
  defp localize_sms_body(_, otp), do: "Your verification code is: #{otp}"
end
```
