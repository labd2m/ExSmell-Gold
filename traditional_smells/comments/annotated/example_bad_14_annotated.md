# Annotated Example

- **Smell name:** Comments
- **Expected smell location:** `NotificationDispatcher.dispatch/2`
- **Affected function(s):** `dispatch/2`
- **Short explanation:** The function's purpose, parameters, and return values are described in plain `#` comment lines instead of using `@doc`, making the documentation inaccessible to tooling.

```elixir
defmodule MyApp.Notifications.NotificationDispatcher do
  @moduledoc """
  Dispatches notifications to users across multiple channels:
  email, SMS, push, and in-app. Channel selection is driven by
  the user's notification preferences and the notification's priority level.
  """

  alias MyApp.Repo
  alias MyApp.Accounts.User
  alias MyApp.Notifications.{Notification, Preference, DeliveryLog}
  alias MyApp.Notifications.Channels.{Email, SMS, Push, InApp}

  require Logger

  @high_priority_channels [:email, :sms, :push, :in_app]
  @normal_priority_channels [:email, :in_app]
  @low_priority_channels [:in_app]

  # VALIDATION: SMELL START - Comments
  # VALIDATION: This is a smell because dispatch/2 uses plain # comments for documentation
  # instead of @doc, so the documentation is invisible to ExDoc and IEx.h/1.

  # Dispatches a notification to the target user via all applicable channels.
  #
  # Parameters:
  #   notification - a %Notification{} struct with at minimum :user_id, :type,
  #                  :subject, :body, and :priority fields populated.
  #   opts         - keyword list of dispatch options:
  #                    :dry_run (boolean) - if true, build but do not send (default false)
  #                    :force_channels (list) - override channel selection
  #
  # The function resolves the user's preferences and intersects them with the
  # channels appropriate for the notification's priority level.
  #
  # Returns {:ok, delivery_results} where delivery_results is a list of
  # %{channel: atom, status: :sent | :skipped | :failed} maps.
  def dispatch(%Notification{} = notification, opts \\ []) do
  # VALIDATION: SMELL END
    dry_run = Keyword.get(opts, :dry_run, false)

    with {:ok, user} <- fetch_user(notification.user_id),
         channels <- resolve_channels(user, notification, opts) do
      results =
        Enum.map(channels, fn channel ->
          if dry_run do
            %{channel: channel, status: :skipped}
          else
            send_via_channel(channel, user, notification)
          end
        end)

      log_delivery(notification, results)

      {:ok, results}
    end
  end

  @doc """
  Schedules a notification to be dispatched at a specific future time.

  ## Parameters

    - `notification` – a `%Notification{}` struct.
    - `deliver_at` – a `%DateTime{}` in UTC at which to deliver.

  ## Returns

  `{:ok, job}` with the scheduled Oban job, or `{:error, reason}`.
  """
  def schedule(%Notification{} = notification, %DateTime{} = deliver_at) do
    delay_seconds = DateTime.diff(deliver_at, DateTime.utc_now())

    if delay_seconds < 0 do
      {:error, :deliver_at_in_the_past}
    else
      %{notification_id: notification.id}
      |> MyApp.Workers.NotificationWorker.new(schedule_in: delay_seconds)
      |> Oban.insert()
    end
  end

  @doc """
  Retrieves the delivery history for a notification.
  """
  def delivery_history(notification_id) do
    logs =
      DeliveryLog
      |> DeliveryLog.for_notification(notification_id)
      |> Repo.all()

    {:ok, logs}
  end

  # --- Private helpers ---

  defp fetch_user(user_id) do
    case Repo.get(User, user_id) do
      nil -> {:error, :user_not_found}
      user -> {:ok, user}
    end
  end

  defp resolve_channels(user, %Notification{priority: priority}, opts) do
    forced = Keyword.get(opts, :force_channels)

    if forced do
      forced
    else
      eligible = priority_channels(priority)
      prefs = user_preferences(user)
      Enum.filter(eligible, &(&1 in prefs))
    end
  end

  defp priority_channels(:high), do: @high_priority_channels
  defp priority_channels(:normal), do: @normal_priority_channels
  defp priority_channels(:low), do: @low_priority_channels
  defp priority_channels(_), do: @normal_priority_channels

  defp user_preferences(%User{id: user_id}) do
    case Repo.get_by(Preference, user_id: user_id) do
      nil -> @normal_priority_channels
      prefs -> prefs.enabled_channels
    end
  end

  defp send_via_channel(:email, user, notification) do
    case Email.send(user, notification) do
      :ok -> %{channel: :email, status: :sent}
      {:error, reason} ->
        Logger.warning("Email dispatch failed", reason: reason, user_id: user.id)
        %{channel: :email, status: :failed}
    end
  end

  defp send_via_channel(:sms, user, notification) do
    case SMS.send(user, notification) do
      :ok -> %{channel: :sms, status: :sent}
      {:error, _} -> %{channel: :sms, status: :failed}
    end
  end

  defp send_via_channel(:push, user, notification) do
    case Push.send(user, notification) do
      :ok -> %{channel: :push, status: :sent}
      {:error, _} -> %{channel: :push, status: :failed}
    end
  end

  defp send_via_channel(:in_app, user, notification) do
    case InApp.send(user, notification) do
      :ok -> %{channel: :in_app, status: :sent}
      {:error, _} -> %{channel: :in_app, status: :failed}
    end
  end

  defp log_delivery(%Notification{id: id}, results) do
    Enum.each(results, fn %{channel: channel, status: status} ->
      %DeliveryLog{}
      |> DeliveryLog.changeset(%{notification_id: id, channel: channel, status: status})
      |> Repo.insert()
    end)
  end
end
```
