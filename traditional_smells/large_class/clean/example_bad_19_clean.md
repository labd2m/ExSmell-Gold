```elixir
defmodule NotificationService do
  @moduledoc """
  Sends and tracks notifications across all supported channels.
  """

  require Logger

  alias MyApp.Repo
  alias MyApp.Notifications.{Notification, DeliveryRecord, UserPreference, RateLimitBucket}
  alias MyApp.Mailer
  alias MyApp.SMSGateway
  alias MyApp.PushGateway
  alias Phoenix.PubSub

  @rate_limit_window_seconds 3600
  @rate_limit_max_per_hour 20
  @supported_channels [:email, :sms, :push, :in_app]


  def notify(user_id, event, payload) do
    prefs = load_preferences(user_id)
    channels = resolve_channels(event, prefs)

    Enum.each(channels, fn channel ->
      if within_rate_limit?(user_id, channel) do
        dispatch(channel, user_id, event, payload)
        record_delivery(user_id, channel, event, :sent)
        bump_rate_bucket(user_id, channel)
      else
        Logger.warning("Rate limit hit for user #{user_id} on channel #{channel}")
        record_delivery(user_id, channel, event, :rate_limited)
      end
    end)
  end

  defp dispatch(:email, user_id, event, payload) do
    user = MyApp.Repo.get!(MyApp.Accounts.User, user_id)
    {subject, body} = render_template(:email, event, payload)

    Mailer.send(%{
      to: user.email,
      subject: subject,
      body: body
    })
  end

  defp dispatch(:sms, user_id, event, payload) do
    user = MyApp.Repo.get!(MyApp.Accounts.User, user_id)
    {_, body} = render_template(:sms, event, payload)

    SMSGateway.send(%{
      to: user.phone_number,
      body: truncate(body, 160)
    })
  end

  defp dispatch(:push, user_id, event, payload) do
    tokens = MyApp.Repo.all(
      from d in MyApp.Devices.Device,
        where: d.user_id == ^user_id and d.active == true,
        select: d.push_token
    )

    {title, body} = render_template(:push, event, payload)

    Enum.each(tokens, fn token ->
      PushGateway.send(%{token: token, title: title, body: body, data: payload})
    end)
  end

  defp dispatch(:in_app, user_id, event, payload) do
    {_, body} = render_template(:in_app, event, payload)

    PubSub.broadcast(MyApp.PubSub, "user:#{user_id}", %{
      event: event,
      message: body,
      payload: payload,
      sent_at: DateTime.utc_now()
    })
  end


  defp render_template(:email, :invoice_ready, %{invoice_id: id, amount: amt}) do
    {"Invoice Ready", "Your invoice ##{id} for #{amt} is ready for payment."}
  end

  defp render_template(:email, :password_reset, %{token: token}) do
    {"Reset Your Password", "Click here: https://app.example.com/reset?token=#{token}"}
  end

  defp render_template(:sms, :invoice_ready, %{amount: amt}) do
    {"", "Your invoice for #{amt} is due. Log in to pay."}
  end

  defp render_template(:push, :invoice_ready, %{amount: amt}) do
    {"Invoice Ready", "You owe #{amt}. Tap to pay."}
  end

  defp render_template(channel, event, _payload) do
    Logger.debug("No template for channel=#{channel} event=#{event}, using default")
    {"Notification", "You have a new notification."}
  end

  defp truncate(str, max) when byte_size(str) > max, do: binary_part(str, 0, max - 3) <> "..."
  defp truncate(str, _), do: str


  def load_preferences(user_id) do
    case Repo.get_by(UserPreference, user_id: user_id) do
      nil -> %{channels: @supported_channels, do_not_disturb: false, digest_mode: false}
      prefs -> prefs
    end
  end

  def update_preferences(user_id, attrs) do
    prefs = Repo.get_by(UserPreference, user_id: user_id) || %UserPreference{user_id: user_id}

    prefs
    |> UserPreference.changeset(attrs)
    |> Repo.insert_or_update()
  end

  defp resolve_channels(_event, %{do_not_disturb: true}), do: [:in_app]
  defp resolve_channels(_event, %{channels: channels}), do: channels
  defp resolve_channels(_event, _), do: @supported_channels


  defp within_rate_limit?(user_id, channel) do
    key = "#{user_id}:#{channel}"
    now = System.system_time(:second)
    window_start = now - @rate_limit_window_seconds

    count =
      case Repo.get_by(RateLimitBucket, key: key) do
        nil -> 0
        %{count: c, window_start: ws} when ws >= window_start -> c
        _ -> 0
      end

    count < @rate_limit_max_per_hour
  end

  defp bump_rate_bucket(user_id, channel) do
    key = "#{user_id}:#{channel}"
    now = System.system_time(:second)

    case Repo.get_by(RateLimitBucket, key: key) do
      nil ->
        Repo.insert(%RateLimitBucket{key: key, count: 1, window_start: now})

      bucket ->
        bucket
        |> RateLimitBucket.changeset(%{count: bucket.count + 1})
        |> Repo.update()
    end
  end


  defp record_delivery(user_id, channel, event, status) do
    %DeliveryRecord{
      user_id: user_id,
      channel: channel,
      event: event,
      status: status,
      recorded_at: DateTime.utc_now()
    }
    |> Repo.insert()
  end

  def delivery_history(user_id, opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)
    since = Keyword.get(opts, :since, DateTime.add(DateTime.utc_now(), -7 * 86400, :second))

    Repo.all(
      from d in DeliveryRecord,
        where: d.user_id == ^user_id and d.recorded_at >= ^since,
        order_by: [desc: d.recorded_at],
        limit: ^limit
    )
  end
end
```
