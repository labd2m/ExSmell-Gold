```elixir
defmodule MyApp.Notifications.NotificationDispatcher do
  @moduledoc """
  Dispatches email, SMS, and push notifications to users.
  Supports template rendering, priority queuing, and delivery tracking.
  """

  require Logger

  alias MyApp.Notifications.{TemplateRenderer, DeliveryTracker, Queue}
  alias MyApp.Notifications.Adapters.{Mailer, SMSGateway, PushService}

  @default_from "noreply@myapp.com"
  @max_subject_length 150
  @supported_channels [:email, :sms, :push]

  @type notification_opts :: [
          from: String.t(),
          cc: [String.t()],
          reply_to: String.t(),
          priority: :low | :normal | :high,
          track_opens: boolean()
        ]

  @spec send_email(term(), String.t(), map(), notification_opts()) ::
          {:ok, String.t()} | {:error, atom()}
  def send_email(recipient, template_name, context, opts \\ []) do
    from = Keyword.get(opts, :from, @default_from)
    priority = Keyword.get(opts, :priority, :normal)
    track_opens = Keyword.get(opts, :track_opens, true)

    normalized_recipient = String.downcase(recipient)

    with {:ok, subject, body_html, body_text} <-
           TemplateRenderer.render(template_name, context),
         :ok <- validate_subject(subject),
         {:ok, message_id} <-
           Mailer.deliver(%{
             to: normalized_recipient,
             from: from,
             subject: subject,
             html_body: maybe_inject_tracking(body_html, track_opens),
             text_body: body_text,
             cc: Keyword.get(opts, :cc, []),
             reply_to: Keyword.get(opts, :reply_to)
           }) do
      DeliveryTracker.record(:email, normalized_recipient, message_id, priority)
      Logger.info("Email dispatched to #{normalized_recipient}, message_id=#{message_id}")
      {:ok, message_id}
    else
      {:error, reason} = err ->
        Logger.error("Email dispatch failed to #{inspect(recipient)}: #{inspect(reason)}")
        err
    end
  end

  @spec send_sms(String.t(), String.t(), map()) :: {:ok, String.t()} | {:error, atom()}
  def send_sms(phone_number, template_name, context) do
    with {:ok, _subject, _html, text_body} <- TemplateRenderer.render(template_name, context),
         {:ok, message_id} <- SMSGateway.send(phone_number, text_body) do
      DeliveryTracker.record(:sms, phone_number, message_id, :normal)
      {:ok, message_id}
    end
  end

  @spec send_push(String.t(), String.t(), map(), keyword()) ::
          {:ok, String.t()} | {:error, atom()}
  def send_push(device_token, template_name, context, opts \\ []) do
    with {:ok, subject, _html, text_body} <- TemplateRenderer.render(template_name, context) do
      PushService.notify(%{
        token: device_token,
        title: subject,
        body: text_body,
        badge: Keyword.get(opts, :badge),
        data: Keyword.get(opts, :data, %{})
      })
    end
  end

  @spec broadcast(String.t(), [String.t()], map()) :: %{sent: integer(), failed: integer()}
  def broadcast(template_name, recipients, context) do
    results =
      Enum.map(recipients, fn r ->
        send_email(r, template_name, context)
      end)

    %{
      sent: Enum.count(results, &match?({:ok, _}, &1)),
      failed: Enum.count(results, &match?({:error, _}, &1))
    }
  end

  # Private helpers

  defp validate_subject(subject) when byte_size(subject) > @max_subject_length,
    do: {:error, :subject_too_long}

  defp validate_subject(_subject), do: :ok

  defp maybe_inject_tracking(html, true) do
    pixel = ~s(<img src="#{tracking_pixel_url()}" width="1" height="1" />)
    html <> pixel
  end

  defp maybe_inject_tracking(html, false), do: html

  defp tracking_pixel_url do
    token = :crypto.strong_rand_bytes(8) |> Base.url_encode64(padding: false)
    "https://track.myapp.com/open/#{token}.gif"
  end
end
```
