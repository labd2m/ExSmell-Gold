```elixir

defmodule MyApp.Notifications.Dispatcher do
  alias MyApp.Notifications.{Formatter, RateLimiter}
  alias MyApp.Adapters.{EmailAdapter, SmsAdapter, SlackAdapter}

  require Logger

  def dispatch(%{channel: :email} = notification, opts \\ []) do
    with :ok <- RateLimiter.check(:email, notification.recipient_id),
         {:ok, payload} <- Formatter.build_payload(notification, :email),
         {:ok, _ref} <- EmailAdapter.deliver(payload, opts) do
      log_delivery(:email, notification.id, :ok)
      {:ok, :delivered}
    else
      {:error, reason} ->
        log_delivery(:email, notification.id, {:error, reason})
        {:error, reason}
    end
  end

  def dispatch(%{channel: :sms} = notification, opts \\ []) do
    with :ok <- RateLimiter.check(:sms, notification.recipient_id),
         {:ok, payload} <- Formatter.build_payload(notification, :sms),
         {:ok, _ref} <- SmsAdapter.deliver(payload, opts) do
      log_delivery(:sms, notification.id, :ok)
      {:ok, :delivered}
    else
      {:error, reason} ->
        log_delivery(:sms, notification.id, {:error, reason})
        {:error, reason}
    end
  end

  def dispatch(%{channel: :slack} = notification, opts \\ []) do
    with :ok <- RateLimiter.check(:slack, notification.recipient_id),
         {:ok, payload} <- Formatter.build_payload(notification, :slack),
         {:ok, _ref} <- SlackAdapter.deliver(payload, opts) do
      log_delivery(:slack, notification.id, :ok)
      {:ok, :delivered}
    else
      {:error, reason} ->
        log_delivery(:slack, notification.id, {:error, reason})
        {:error, reason}
    end
  end

  def dispatch(%{channel: unknown}, _opts) do
    {:error, {:unsupported_channel, unknown}}
  end

  defp log_delivery(channel, notification_id, result) do
    Logger.info("[Notifications] Delivery attempt",
      channel: channel,
      notification_id: notification_id,
      result: result
    )
  end
end

defmodule MyApp.Notifications.Formatter do
  def build_payload(%{type: :welcome} = n, :email) do
    {:ok,
     %{
       to: n.recipient_email,
       subject: "Welcome to #{n.app_name}!",
       html_body: "<h1>Hello #{n.user_name}</h1><p>Your account is ready.</p>",
       text_body: "Hello #{n.user_name}, your account is ready."
     }}
  end

  def build_payload(%{type: :welcome} = n, :sms) do
    {:ok, %{to: n.phone_number, body: "Welcome #{n.user_name}! Visit #{n.login_url} to get started."}}
  end

  def build_payload(%{type: :welcome} = n, :slack) do
    {:ok, %{channel: n.slack_channel, text: ":wave: Welcome *#{n.user_name}* to #{n.app_name}!"}}
  end

  def build_payload(%{type: :payment_failed} = n, :email) do
    {:ok,
     %{
       to: n.recipient_email,
       subject: "Payment failed – action required",
       html_body: "<p>Your payment of $#{n.amount} failed. Please update your billing info.</p>",
       text_body: "Your payment of $#{n.amount} failed. Please update your billing info."
     }}
  end

  def build_payload(%{type: :payment_failed} = n, :sms) do
    {:ok, %{to: n.phone_number, body: "Payment of $#{n.amount} failed. Update your card at #{n.update_url}"}}
  end

  def build_payload(%{type: :payment_failed} = n, :slack) do
    {:ok,
     %{
       channel: n.slack_channel,
       text: ":x: Payment of *$#{n.amount}* failed for #{n.user_name}."
     }}
  end

  def build_payload(%{type: type}, channel) do
    {:error, {:no_template, type, channel}}
  end
end

defmodule MyApp.Notifications.RateLimiter do
  @moduledoc """
  Enforces per-channel, per-recipient hourly rate limits using an ETS-backed counter store.
  Limits are defined per channel and checked on every dispatch attempt.
  """

  @email_hourly_limit 50
  @sms_hourly_limit 5
  @slack_hourly_limit 30

  def check(channel, recipient_id) do
    limit = get_limit(channel)
    window_key = {channel, recipient_id, current_window()}
    count = :ets.update_counter(:notif_rate_limits, window_key, {2, 1}, {window_key, 0})

    if count <= limit do
      :ok
    else
      {:error, :rate_limit_exceeded}
    end
  end

  def get_limit(:email), do: @email_hourly_limit
  def get_limit(:sms), do: @sms_hourly_limit
  def get_limit(:slack), do: @slack_hourly_limit
  def get_limit(_), do: 0

  defp current_window, do: System.system_time(:second) |> div(3600)
end
```
