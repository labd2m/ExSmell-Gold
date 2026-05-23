```elixir
defmodule Notifications.Dispatcher do
  @moduledoc """
  Routes outbound notifications to the appropriate delivery backend
  based on the resolved channel type for each recipient.
  """

  alias Notifications.Formatter


  @spec dispatch(atom(), map()) :: {:ok, reference()} | {:error, term()}
  def dispatch(:email, notification) do
    body = Formatter.format_message(:email, notification)

    Swoosh.deliver(%Swoosh.Email{
      to:      notification.recipient.email,
      from:    {"Acme Alerts", "alerts@acme.io"},
      subject: notification.subject,
      html_body: body
    })
    |> case do
      {:ok, _meta} -> {:ok, make_ref()}
      {:error, err} -> {:error, err}
    end
  end

  def dispatch(:sms, notification) do
    body = Formatter.format_message(:sms, notification)

    ExTwilio.Message.create(
      to:   notification.recipient.phone,
      from: System.get_env("TWILIO_FROM"),
      body: body
    )
    |> case do
      {:ok, _msg} -> {:ok, make_ref()}
      {:error, err} -> {:error, err}
    end
  end

  def dispatch(:push, notification) do
    body = Formatter.format_message(:push, notification)

    Pigeon.APNS.push(%Pigeon.APNS.Notification{
      device_token: notification.recipient.device_token,
      topic:        System.get_env("APNS_TOPIC"),
      alert:        %{"title" => notification.subject, "body" => body}
    })
    |> case do
      %{response: :success} -> {:ok, make_ref()}
      %{response: err}      -> {:error, err}
    end
  end

  @spec channel_label(atom()) :: String.t()
  def channel_label(:email), do: "Email"
  def channel_label(:sms),   do: "SMS"
  def channel_label(:push),  do: "Push Notification"


  def dispatch_all(notifications) do
    Enum.map(notifications, fn n ->
      channel = resolve_channel(n.recipient)
      case Notifications.RateLimiter.check(channel, n.recipient.id) do
        :ok    -> dispatch(channel, n)
        :limit -> {:error, :rate_limited}
      end
    end)
  end

  defp resolve_channel(%{device_token: token}) when is_binary(token), do: :push
  defp resolve_channel(%{phone: phone}) when is_binary(phone),        do: :sms
  defp resolve_channel(_),                                             do: :email
end

defmodule Notifications.Formatter do
  @moduledoc """
  Renders notification content into channel-appropriate formats,
  respecting character limits and markup constraints per channel.
  """


  @spec format_message(atom(), map()) :: String.t()
  def format_message(:email, %{body: body, recipient: %{name: name}}) do
    """
    <html>
      <body>
        <p>Hi #{name},</p>
        <p>#{body}</p>
        <p>— The Acme Team</p>
      </body>
    </html>
    """
  end

  def format_message(:sms, %{body: body}) do
    body
    |> String.slice(0, 160)
    |> Kernel.<>(" Reply STOP to unsubscribe.")
  end

  def format_message(:push, %{body: body}) do
    String.slice(body, 0, 100)
  end

end

defmodule Notifications.RateLimiter do
  @moduledoc """
  Enforces per-channel, per-recipient rate limits to prevent notification
  flooding and protect sender reputation scores.
  """


  @spec rate_limit_key(atom()) :: String.t()
  def rate_limit_key(:email), do: "notif:email"
  def rate_limit_key(:sms),   do: "notif:sms"
  def rate_limit_key(:push),  do: "notif:push"

  @spec max_per_minute(atom()) :: pos_integer()
  def max_per_minute(:email), do: 10
  def max_per_minute(:sms),   do: 5
  def max_per_minute(:push),  do: 20


  def check(channel, recipient_id) do
    key     = "#{rate_limit_key(channel)}:#{recipient_id}"
    limit   = max_per_minute(channel)
    current = Cachex.get(:rate_cache, key) |> elem(1) |> Kernel.||(0)

    if current >= limit do
      :limit
    else
      Cachex.put(:rate_cache, key, current + 1, ttl: :timer.seconds(60))
      :ok
    end
  end
end
```
