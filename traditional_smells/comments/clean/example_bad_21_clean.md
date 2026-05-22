```elixir
defmodule MyApp.NotificationDispatcher do
  @moduledoc """
  Routes outbound notifications to the appropriate delivery channel
  (email, SMS, push, or in-app) based on user preferences and
  notification type priority rules.
  """

  alias MyApp.{Repo, User, NotificationPreference, NotificationLog}
  alias MyApp.Channels.{EmailChannel, SmsChannel, PushChannel, InAppChannel}
  require Logger

  @channel_priority [:push, :email, :sms, :in_app]


  # dispatch/2
  #
  # Sends a notification to a user through the preferred delivery channel.
  #
  # Arguments:
  #   - user_id: the integer ID of the target user
  #   - notification: a map containing:
  #       :type   — atom such as :order_shipped, :payment_failed, :promo
  #       :title  — string subject or headline
  #       :body   — string message body
  #       :metadata — optional map of extra key/value pairs
  #
  # Behavior:
  #   Looks up the user's channel preferences. For each channel in priority
  #   order, it attempts delivery. On the first success, it logs the result
  #   and returns {:ok, channel_used}. If all channels fail it returns
  #   {:error, :all_channels_failed}.

  def dispatch(user_id, %{type: type, title: title, body: body} = notification) do
    metadata = Map.get(notification, :metadata, %{})

    with {:ok, user} <- load_user(user_id),
         {:ok, prefs} <- load_preferences(user_id) do
      channels = resolve_channels(prefs, type)

      result =
        Enum.reduce_while(channels, {:error, :all_channels_failed}, fn channel, _acc ->
          case deliver(channel, user, title, body, metadata) do
            :ok ->
              log_delivery(user_id, channel, type, :success)
              {:halt, {:ok, channel}}

            {:error, reason} ->
              Logger.warning("[Notif] Channel #{channel} failed for user #{user_id}: #{reason}")
              log_delivery(user_id, channel, type, :failed)
              {:cont, {:error, :all_channels_failed}}
          end
        end)

      result
    end
  end

  @doc """
  Updates a user's notification channel preferences.

  Accepts a list of enabled channels as atoms. Any channel not in the list
  will be disabled. Returns `{:ok, preference}` or `{:error, changeset}`.
  """
  def update_preferences(user_id, enabled_channels) when is_list(enabled_channels) do
    prefs = Repo.get_by(NotificationPreference, user_id: user_id) || %NotificationPreference{}

    prefs
    |> NotificationPreference.changeset(%{
      user_id: user_id,
      channels: enabled_channels
    })
    |> Repo.insert_or_update()
  end

  @doc """
  Returns a list of recent notification logs for a user, ordered by most recent first.
  Defaults to the last 50 entries.
  """
  def recent_logs(user_id, limit \\ 50) do
    Repo.all(
      from(l in NotificationLog,
        where: l.user_id == ^user_id,
        order_by: [desc: l.inserted_at],
        limit: ^limit
      )
    )
  end

  ## Private

  defp load_user(user_id) do
    case Repo.get(User, user_id) do
      nil -> {:error, :user_not_found}
      user -> {:ok, user}
    end
  end

  defp load_preferences(user_id) do
    case Repo.get_by(NotificationPreference, user_id: user_id) do
      nil -> {:ok, %NotificationPreference{channels: @channel_priority}}
      prefs -> {:ok, prefs}
    end
  end

  defp resolve_channels(%NotificationPreference{channels: channels}, type) do
    priority_override =
      case type do
        :payment_failed -> [:sms, :email, :push, :in_app]
        :security_alert -> [:sms, :push, :email, :in_app]
        _ -> @channel_priority
      end

    Enum.filter(priority_override, &(&1 in channels))
  end

  defp deliver(:email, user, title, body, meta),
    do: EmailChannel.send(user.email, title, body, meta)

  defp deliver(:sms, user, title, _body, meta),
    do: SmsChannel.send(user.phone_number, title, meta)

  defp deliver(:push, user, title, body, meta),
    do: PushChannel.send(user.push_token, title, body, meta)

  defp deliver(:in_app, user, title, body, meta),
    do: InAppChannel.insert(user.id, title, body, meta)

  defp log_delivery(user_id, channel, type, status) do
    %NotificationLog{}
    |> NotificationLog.changeset(%{
      user_id: user_id,
      channel: channel,
      notification_type: type,
      status: status,
      sent_at: DateTime.utc_now()
    })
    |> Repo.insert()
  end
end
```
