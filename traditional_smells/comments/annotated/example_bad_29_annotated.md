# Annotated Example 29

- **Smell name:** Comments
- **Expected smell location:** `NotificationDispatcher.dispatch/2`
- **Affected function(s):** `dispatch/2`
- **Short explanation:** Documentation for `dispatch/2` is written as a block of `#` comments rather than an `@doc` attribute, which is the idiomatic Elixir convention. This prevents the documentation from appearing in ExDoc output or IEx's `h/1` helper.

```elixir
defmodule MyApp.NotificationDispatcher do
  @moduledoc """
  Routes outbound notifications to the appropriate delivery channel
  (email, SMS, push) based on user preferences and notification type.
  """

  alias MyApp.Accounts.User
  alias MyApp.Notifications.{EmailSender, SmsSender, PushSender, NotificationLog}
  alias MyApp.Repo

  require Logger

  @supported_channels [:email, :sms, :push]

  # VALIDATION: SMELL START - Comments
  # VALIDATION: This is a smell because `dispatch/2` is described entirely through `#` comments
  # VALIDATION: rather than `@doc`, making the documentation invisible to tooling and documentation
  # VALIDATION: generators.

  # dispatch/2
  #
  # Sends a notification to a user through all channels enabled in their preferences.
  # The `notification` argument is a map with the following required keys:
  #   - :type       — atom, e.g. :password_reset, :order_shipped, :promo
  #   - :subject    — string, used as email subject or push title
  #   - :body       — string, the notification body text
  #   - :metadata   — map of additional key-value pairs (may be empty)
  #
  # Channels are attempted independently; a failure on one channel does not
  # prevent delivery on others. Each attempt is logged to the notification_logs table.
  #
  # Returns a map of channel => result, e.g.:
  #   %{email: :ok, sms: {:error, :provider_timeout}, push: :ok}
  def dispatch(%User{} = user, notification) do
    # VALIDATION: SMELL END
    channels = resolve_channels(user, notification.type)

    Logger.info("Dispatching #{notification.type} to user #{user.id} via #{inspect(channels)}")

    results =
      channels
      |> Enum.map(fn channel ->
        result = send_via_channel(channel, user, notification)
        log_attempt(user, notification, channel, result)
        {channel, result}
      end)
      |> Map.new()

    results
  end

  @doc """
  Returns the list of notification channels that are active for `user`
  and appropriate for the given `notification_type`.
  """
  def resolve_channels(%User{} = user, notification_type) do
    user.notification_preferences
    |> Map.get(notification_type, [])
    |> Enum.filter(&(&1 in @supported_channels))
  end

  @doc """
  Retrieves the notification history for a user, ordered by most recent first.
  Accepts an optional `:limit` keyword (default 50).
  """
  def history_for_user(user_id, opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)

    NotificationLog
    |> NotificationLog.for_user(user_id)
    |> NotificationLog.ordered_desc()
    |> NotificationLog.limit(limit)
    |> Repo.all()
  end

  # --- Private helpers ---

  defp send_via_channel(:email, user, notification) do
    EmailSender.send(%{
      to: user.email,
      subject: notification.subject,
      body: notification.body
    })
  end

  defp send_via_channel(:sms, user, notification) do
    case user.phone_number do
      nil ->
        {:error, :no_phone_number}

      phone ->
        SmsSender.send(%{to: phone, message: notification.body})
    end
  end

  defp send_via_channel(:push, user, notification) do
    case user.push_token do
      nil ->
        {:error, :no_push_token}

      token ->
        PushSender.send(%{
          token: token,
          title: notification.subject,
          body: notification.body,
          data: notification.metadata
        })
    end
  end

  defp log_attempt(user, notification, channel, result) do
    status = if match?({:error, _}, result), do: :failed, else: :delivered

    %NotificationLog{}
    |> NotificationLog.changeset(%{
      user_id: user.id,
      notification_type: notification.type,
      channel: channel,
      status: status,
      sent_at: DateTime.utc_now()
    })
    |> Repo.insert()
  end
end
```
