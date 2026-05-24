```elixir
defmodule Notifications.NotificationRouter do
  @moduledoc """
  Routes and delivers notifications to users through their preferred
  communication channels (email, SMS, push).
  """

  require Logger

  alias Notifications.{Notification, DeliveryLog, Template}
  alias Accounts.{User, ContactPreference, NotificationSetting}
  alias Adapters.{EmailAdapter, SmsAdapter, PushAdapter}

  @batch_size 100

  def create_notification(user_id, type, payload) do
    %Notification{
      user_id:    user_id,
      type:       type,
      payload:    payload,
      status:     :pending,
      created_at: DateTime.utc_now()
    }
    |> Notification.persist()
  end

  def bulk_notify(user_ids, type, payload) when is_list(user_ids) do
    user_ids
    |> Enum.chunk_every(@batch_size)
    |> Enum.each(fn batch ->
      Enum.each(batch, fn user_id ->
        with {:ok, notif} <- create_notification(user_id, type, payload) do
          deliver(notif)
        end
      end)
    end)

    :ok
  end

  def deliver(%Notification{} = notification) do
    user       = User.fetch!(notification.user_id)
    preference = ContactPreference.for_user(user.id)
    setting    = NotificationSetting.for_user(user.id, notification.type)

    cond do
      setting.opted_in != true ->
        DeliveryLog.record(notification.id, :skipped, "User opted out")
        {:ok, :skipped}

      delivery_count_today(user.id, notification.type) >= setting.frequency_cap_per_day ->
        DeliveryLog.record(notification.id, :skipped, "Frequency cap reached")
        {:ok, :skipped}

      in_quiet_hours?(preference.quiet_hours_start, preference.quiet_hours_end) ->
        Notification.reschedule(notification, next_window_end(preference.quiet_hours_end))
        {:ok, :rescheduled}

      true ->
        template = Template.render(notification.type, notification.payload)

        result =
          case preference.channel do
            :email ->
              EmailAdapter.send(%{
                to:      user.email,
                subject: template.subject,
                body:    template.body
              })

            :sms ->
              SmsAdapter.send(%{
                to:   user.phone_number,
                body: template.short_body
              })

            :push ->
              PushAdapter.send(%{
                token: user.push_token,
                title: template.subject,
                body:  template.body
              })

            other ->
              {:error, "Unknown channel: #{other}"}
          end

        case result do
          {:ok, _} ->
            DeliveryLog.record(notification.id, :delivered)
            Notification.persist(%{notification | status: :delivered, delivered_at: DateTime.utc_now()})

          {:error, reason} ->
            Logger.warning("Delivery failed for notification #{notification.id}: #{inspect(reason)}")
            {:error, reason}
        end
    end
  end

  def mark_read(notification_id, user_id) do
    with {:ok, notif} <- Notification.fetch(notification_id),
         true         <- notif.user_id == user_id do
      Notification.persist(%{notif | read_at: DateTime.utc_now()})
    else
      false -> {:error, :unauthorized}
      err   -> err
    end
  end

  def list_unread(user_id, opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)
    Notification.list(user_id: user_id, read_at: nil, limit: limit)
  end


  defp delivery_count_today(user_id, type) do
    DeliveryLog.count_today(user_id, type)
  end

  defp in_quiet_hours?(start_time, end_time) do
    now = Time.utc_now()
    Time.compare(now, start_time) != :lt and Time.compare(now, end_time) == :lt
  end

  defp next_window_end(end_time) do
    DateTime.new!(Date.utc_today(), end_time, "Etc/UTC")
  end
end
```
