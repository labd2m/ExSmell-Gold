```elixir
defmodule Notifications.Dispatcher do
  @moduledoc """
  Dispatches notifications across multiple delivery channels.
  Handles payload formatting, retry strategies, rate limiting,
  and delivery timeout policies per channel type.
  """

  alias Notifications.{Envelope, EmailAdapter, SmsAdapter, PushAdapter, DeliveryLog}

  def dispatch(%Envelope{} = envelope) do
    with {:ok, payload}   <- format_payload(envelope.template, envelope.channel),
         :ok              <- check_rate_limit(envelope.recipient_id, envelope.channel),
         {:ok, _response} <- deliver(payload, envelope) do
      DeliveryLog.record_success(envelope)
    else
      {:error, :rate_limited} ->
        DeliveryLog.record_throttled(envelope)
        {:error, :rate_limited}

      {:error, reason} ->
        retry_policy = get_retry_policy(envelope.channel)
        DeliveryLog.record_failure(envelope, reason, retry_policy)
        {:error, reason}
    end
  end

  defp deliver(payload, %Envelope{channel: :email} = envelope) do
    EmailAdapter.send(envelope.recipient, payload, timeout: get_delivery_timeout(:email))
  end

  defp deliver(payload, %Envelope{channel: :sms} = envelope) do
    SmsAdapter.send(envelope.recipient, payload, timeout: get_delivery_timeout(:sms))
  end

  defp deliver(payload, %Envelope{channel: :push} = envelope) do
    PushAdapter.send(envelope.device_token, payload, timeout: get_delivery_timeout(:push))
  end

  defp check_rate_limit(recipient_id, channel) do
    limit = get_rate_limit(channel)
    Notifications.RateLimiter.check(recipient_id, channel, limit)
  end

  def format_payload(template, :email) do
    %{
      subject:   template.subject,
      html_body: template.html,
      text_body: template.text,
      headers:   %{"X-Mailer" => "AppNotifier/1.0"}
    }
  end

  def format_payload(template, :sms) do
    body = String.slice(template.text, 0, 160)
    %{body: body, unicode: String.length(body) != byte_size(body)}
  end

  def format_payload(template, :push) do
    %{
      title:    template.subject,
      body:     String.slice(template.text, 0, 100),
      data:     template.metadata,
      badge:    1,
      sound:    "default"
    }
  end

  def get_retry_policy(:email), do: %{max_attempts: 3, backoff_seconds: [60, 300, 900]}
  def get_retry_policy(:sms),   do: %{max_attempts: 5, backoff_seconds: [30, 60, 120, 300, 600]}
  def get_retry_policy(:push),  do: %{max_attempts: 2, backoff_seconds: [10, 60]}
  def get_retry_policy(_),      do: %{max_attempts: 1, backoff_seconds: []}

  def get_rate_limit(:email), do: %{per_minute: 10,  per_hour: 50}
  def get_rate_limit(:sms),   do: %{per_minute: 5,   per_hour: 20}
  def get_rate_limit(:push),  do: %{per_minute: 30,  per_hour: 200}
  def get_rate_limit(_),      do: %{per_minute: 1,   per_hour: 5}

  defp get_delivery_timeout(:email), do: 15_000
  defp get_delivery_timeout(:sms),   do: 8_000
  defp get_delivery_timeout(:push),  do: 5_000
  defp get_delivery_timeout(_),      do: 10_000

  def build_envelope(attrs) do
    %Envelope{
      recipient_id: Map.fetch!(attrs, :recipient_id),
      recipient:    Map.fetch!(attrs, :recipient),
      channel:      Map.fetch!(attrs, :channel),
      template:     Map.fetch!(attrs, :template),
      metadata:     Map.get(attrs, :metadata, %{}),
      device_token: Map.get(attrs, :device_token)
    }
  end

  def supported_channels, do: [:email, :sms, :push]
end
```
