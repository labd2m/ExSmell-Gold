```elixir
defmodule NotificationRouter do
  @moduledoc """
  Routes outbound notifications to the appropriate delivery channel adapters
  based on user preferences and message priority.
  """

  alias NotificationRouter.{
    EmailAdapter,
    SMSAdapter,
    PushAdapter,
    SlackAdapter,
    UserPreference,
    DeliveryLog
  }

  @high_priority_channels [:push, :sms]
  @low_priority_channels [:email, :slack]
  @supported_channels [:email, :sms, :push, :slack]

  @doc """
  Fetches the active notification preferences for a user.
  """
  def preferences_for(user_id) do
    UserPreference.fetch(user_id)
  end

  # dispatch/2
  #
  # Routes a notification message to one or more delivery channels
  # for the target user. The routing logic works as follows:
  #
  #   - If `notification.priority` is :high, the message is sent via
  #     all @high_priority_channels that the user has enabled.
  #   - If `notification.priority` is :low or :normal, the message is sent
  #     via the user's preferred channels from @low_priority_channels.
  #   - If the user has no preferences, falls back to [:email].
  #
  # Each delivery attempt is logged to DeliveryLog regardless of outcome.
  #
  # Parameters:
  #   user_id      - integer user identifier
  #   notification - a map with keys :subject, :body, :priority, and optional :metadata
  #
  # Returns:
  #   {:ok, delivery_results} where delivery_results is a list of
  #   {channel, :ok | {:error, reason}} tuples.
  # plain comments rather than @doc. All the useful information about priority
  # routing, fallback behavior, and return shape is hidden from documentation tools.
  def dispatch(user_id, notification) do
    channels = resolve_channels(user_id, notification.priority)

    results =
      Enum.map(channels, fn channel ->
        result = deliver_to_channel(channel, user_id, notification)
        DeliveryLog.record(user_id, channel, notification, result)
        {channel, result}
      end)

    {:ok, results}
  end

  @doc """
  Retries a failed delivery for a specific channel given a logged delivery ID.
  """
  def retry_delivery(delivery_log_id) do
    with {:ok, log_entry} <- DeliveryLog.fetch(delivery_log_id),
         {:ok, _} <- deliver_to_channel(log_entry.channel, log_entry.user_id, log_entry.notification) do
      DeliveryLog.mark_retried(delivery_log_id)
    end
  end

  defp resolve_channels(user_id, :high) do
    {:ok, prefs} = UserPreference.fetch(user_id)
    Enum.filter(@high_priority_channels, &(&1 in prefs.enabled_channels))
  end

  defp resolve_channels(user_id, priority) when priority in [:low, :normal] do
    case UserPreference.fetch(user_id) do
      {:ok, prefs} ->
        prefs.enabled_channels
        |> Enum.filter(&(&1 in @low_priority_channels))
        |> fallback_if_empty()

      {:error, _} ->
        [:email]
    end
  end

  defp resolve_channels(_user_id, _priority), do: [:email]

  defp fallback_if_empty([]), do: [:email]
  defp fallback_if_empty(channels), do: channels

  defp deliver_to_channel(:email, user_id, notification),
    do: EmailAdapter.send(user_id, notification)

  defp deliver_to_channel(:sms, user_id, notification),
    do: SMSAdapter.send(user_id, notification)

  defp deliver_to_channel(:push, user_id, notification),
    do: PushAdapter.send(user_id, notification)

  defp deliver_to_channel(:slack, user_id, notification),
    do: SlackAdapter.send(user_id, notification)

  defp deliver_to_channel(unknown, _user_id, _notification),
    do: {:error, {:unsupported_channel, unknown}}
end
```
