# Annotated Example — Code Smell

- **Smell name:** Inappropriate Intimacy
- **Expected smell location:** `Notifications.AlertSender.send_alert/3`
- **Affected function(s):** `send_alert/3`, `resolve_channels/1`
- **Short explanation:** `AlertSender` directly reads internal fields of `User` (`user.email_verified`, `user.phone_number`, `user.locale`) and `NotificationPreference` (`pref.channels`, `pref.quiet_hours_start`, `pref.quiet_hours_end`, `pref.timezone`) to decide how and when to send alerts. This logic rightfully belongs inside the `User` and `NotificationPreference` modules.

```elixir
defmodule Notifications.AlertSender do
  @moduledoc """
  Delivers alert messages to users through their configured notification
  channels, respecting quiet-hour windows and channel eligibility.
  """

  require Logger

  alias Notifications.{NotificationPreference, DeliveryRecord}
  alias Accounts.User
  alias Notifications.Adapters.{EmailAdapter, SmsAdapter, PushAdapter}
  alias Repo

  @supported_channels [:email, :sms, :push]

  def send_alert(user_id, alert_type, payload) do
    with {:ok, user} <- User.fetch(user_id),
         {:ok, pref} <- NotificationPreference.for_user(user_id) do
      dispatch(user, pref, alert_type, payload)
    else
      {:error, :not_found} ->
        Logger.warning("Cannot send alert: user #{user_id} not found")
        {:error, :user_not_found}
    end
  end

  # VALIDATION: SMELL START - Inappropriate Intimacy
  # VALIDATION: This is a smell because dispatch/4 and resolve_channels/1 directly
  # VALIDATION: access internal fields of User (email_verified, phone_number, locale)
  # VALIDATION: and NotificationPreference (channels, quiet_hours_start,
  # VALIDATION: quiet_hours_end, timezone), which are implementation details of those
  # VALIDATION: modules. This coupling means any restructuring of User or
  # VALIDATION: NotificationPreference will break AlertSender.
  defp dispatch(user, pref, alert_type, payload) do
    if in_quiet_hours?(pref.quiet_hours_start, pref.quiet_hours_end, pref.timezone) and
         alert_type != :critical do
      Logger.info("Alert suppressed for user #{user.id}: quiet hours active")
      {:ok, :suppressed}
    else
      channels = resolve_channels(user, pref)

      results =
        Enum.map(channels, fn channel ->
          result = deliver_on_channel(channel, user, payload)
          record_delivery(user.id, alert_type, channel, result)
          {channel, result}
        end)

      failed = Enum.filter(results, fn {_, r} -> r != :ok end)

      if Enum.empty?(failed) do
        {:ok, :delivered}
      else
        Logger.warning("Partial delivery failure for user #{user.id}: #{inspect(failed)}")
        {:partial, failed}
      end
    end
  end

  defp resolve_channels(user, pref) do
    Enum.filter(pref.channels, fn channel ->
      channel in @supported_channels and channel_eligible?(channel, user)
    end)
  end

  defp channel_eligible?(:email, user), do: user.email_verified
  defp channel_eligible?(:sms, user), do: not is_nil(user.phone_number)
  defp channel_eligible?(:push, _user), do: true
  # VALIDATION: SMELL END

  defp deliver_on_channel(:email, user, payload) do
    EmailAdapter.send(%{
      to: user.email,
      locale: user.locale,
      template: payload.template,
      vars: payload.vars
    })
  end

  defp deliver_on_channel(:sms, user, payload) do
    SmsAdapter.send(%{
      to: user.phone_number,
      body: payload.sms_body
    })
  end

  defp deliver_on_channel(:push, user, payload) do
    PushAdapter.send(%{
      user_id: user.id,
      title: payload.title,
      body: payload.push_body
    })
  end

  defp in_quiet_hours?(nil, _end, _tz), do: false
  defp in_quiet_hours?(_start, nil, _tz), do: false

  defp in_quiet_hours?(start_hour, end_hour, timezone) do
    {:ok, local_now} = DateTime.now(timezone)
    current_hour = local_now.hour

    if start_hour <= end_hour do
      current_hour >= start_hour and current_hour < end_hour
    else
      current_hour >= start_hour or current_hour < end_hour
    end
  end

  defp record_delivery(user_id, alert_type, channel, result) do
    %DeliveryRecord{
      user_id: user_id,
      alert_type: alert_type,
      channel: channel,
      status: if(result == :ok, do: :delivered, else: :failed),
      attempted_at: DateTime.utc_now()
    }
    |> Repo.insert()
  end
end
```
