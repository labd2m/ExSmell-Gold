# Code Smell Annotation

- **Smell name:** Large Class (Large Module)
- **Expected smell location:** The entire `NotificationService` module
- **Affected function(s):** `send_email/3`, `send_sms/2`, `send_push/3`, `broadcast_in_app/2`, `get_user_preferences/1`, `update_user_preferences/2`, `schedule_notification/3`, `cancel_scheduled/1`, `record_delivery/3`, `delivery_stats/2`
- **Short explanation:** `NotificationService` handles e-mail dispatch, SMS, push notifications, in-app broadcasts, user preference management, scheduled delivery, and delivery analytics — all unrelated delivery channels and concerns forced into one module. Each channel and each cross-cutting concern (preferences, scheduling, analytics) deserves its own cohesive module.

```elixir
# VALIDATION: SMELL START - Large Class (Large Module)
# VALIDATION: This is a smell because NotificationService handles multiple
# unrelated delivery channels (email, SMS, push, in-app), plus user preference
# management, scheduling logic, and delivery analytics — all distinct business
# concerns that should be separated into focused modules.
defmodule MyApp.NotificationService do
  @moduledoc """
  Unified service for sending notifications across all channels and
  managing delivery preferences, scheduling, and delivery tracking.
  """

  require Logger
  import Ecto.Query

  alias MyApp.Repo
  alias MyApp.Notifications.{DeliveryRecord, ScheduledNotification, UserPreference}
  alias MyApp.Accounts.User

  @push_ttl_seconds 86_400
  @sms_sender       "+15550001234"

  # -------------------------------------------------------------------
  # Email delivery
  # -------------------------------------------------------------------

  def send_email(to_user_id, template, assigns) when is_atom(template) do
    user = Repo.get!(User, to_user_id)

    unless email_opted_out?(user.id, :email) do
      body = MyApp.EmailRenderer.render(template, assigns)

      result = MyApp.Mailer.deliver(%{
        to:      user.email,
        subject: subject_for(template),
        html:    body
      })

      record_delivery(user.id, :email, result)
    end
  end

  defp subject_for(:welcome),           do: "Welcome to MyApp!"
  defp subject_for(:invoice_ready),     do: "Your invoice is ready"
  defp subject_for(:password_reset),    do: "Reset your password"
  defp subject_for(:subscription_end),  do: "Your subscription is ending soon"
  defp subject_for(_),                  do: "Notification from MyApp"

  # -------------------------------------------------------------------
  # SMS delivery
  # -------------------------------------------------------------------

  def send_sms(to_user_id, message) when is_binary(message) do
    user = Repo.get!(User, to_user_id)

    unless sms_opted_out?(user.id) or is_nil(user.phone_number) do
      truncated = String.slice(message, 0, 160)

      result = MyApp.SMSGateway.send(%{
        from:    @sms_sender,
        to:      user.phone_number,
        body:    truncated
      })

      case result do
        {:ok, sid}  ->
          Logger.info("SMS #{sid} sent to user #{user.id}")
          record_delivery(user.id, :sms, {:ok, sid})

        {:error, reason} ->
          Logger.warning("SMS failed for user #{user.id}: #{inspect(reason)}")
          record_delivery(user.id, :sms, {:error, to_string(reason)})
      end
    end
  end

  defp sms_opted_out?(user_id) do
    email_opted_out?(user_id, :sms)
  end

  # -------------------------------------------------------------------
  # Push notifications
  # -------------------------------------------------------------------

  def send_push(to_user_id, title, body) do
    tokens = Repo.all(
      from t in MyApp.Notifications.DeviceToken,
        where: t.user_id == ^to_user_id and t.active == true
    )

    unless email_opted_out?(to_user_id, :push) or Enum.empty?(tokens) do
      Enum.each(tokens, fn token ->
        result = MyApp.PushGateway.send(%{
          device_token: token.value,
          platform:     token.platform,
          title:        title,
          body:         body,
          ttl:          @push_ttl_seconds
        })

        case result do
          {:ok, _}              -> :ok
          {:error, :invalid_token} ->
            Repo.update!(MyApp.Notifications.DeviceToken.changeset(token, %{active: false}))
          {:error, reason} ->
            Logger.warning("Push failed for token #{token.id}: #{inspect(reason)}")
        end
      end)

      record_delivery(to_user_id, :push, {:ok, length(tokens)})
    end
  end

  # -------------------------------------------------------------------
  # In-app broadcast
  # -------------------------------------------------------------------

  def broadcast_in_app(to_user_id, payload) when is_map(payload) do
    topic = "user:#{to_user_id}"

    MyApp.Endpoint.broadcast!(topic, "notification", payload)

    Repo.insert!(%DeliveryRecord{
      user_id:   to_user_id,
      channel:   :in_app,
      status:    :delivered,
      payload:   payload,
      sent_at:   DateTime.utc_now()
    })
  end

  # -------------------------------------------------------------------
  # User preference management
  # -------------------------------------------------------------------

  def get_user_preferences(user_id) do
    case Repo.get_by(UserPreference, user_id: user_id) do
      nil  -> %{email: true, sms: false, push: true, in_app: true}
      pref -> Map.take(pref, [:email, :sms, :push, :in_app])
    end
  end

  def update_user_preferences(user_id, changes) when is_map(changes) do
    allowed = Map.take(changes, [:email, :sms, :push, :in_app])

    pref = Repo.get_by(UserPreference, user_id: user_id) || %UserPreference{user_id: user_id}

    pref
    |> UserPreference.changeset(allowed)
    |> Repo.insert_or_update()
  end

  defp email_opted_out?(user_id, channel) do
    prefs = get_user_preferences(user_id)
    not Map.get(prefs, channel, true)
  end

  # -------------------------------------------------------------------
  # Scheduled notifications
  # -------------------------------------------------------------------

  def schedule_notification(user_id, channel, deliver_at, payload) do
    Repo.insert(%ScheduledNotification{
      user_id:    user_id,
      channel:    channel,
      deliver_at: deliver_at,
      payload:    payload,
      status:     :pending
    })
  end

  def cancel_scheduled(notification_id) do
    case Repo.get(ScheduledNotification, notification_id) do
      nil  -> {:error, :not_found}
      notif ->
        Repo.update!(ScheduledNotification.changeset(notif, %{status: :canceled}))
        {:ok, :canceled}
    end
  end

  def flush_due_notifications do
    now = DateTime.utc_now()

    due =
      from(n in ScheduledNotification,
        where: n.deliver_at <= ^now and n.status == :pending
      )
      |> Repo.all()

    Enum.each(due, fn notif ->
      case notif.channel do
        :email  -> send_email(notif.user_id, notif.payload[:template], notif.payload[:assigns] || %{})
        :sms    -> send_sms(notif.user_id, notif.payload[:message])
        :push   -> send_push(notif.user_id, notif.payload[:title], notif.payload[:body])
        :in_app -> broadcast_in_app(notif.user_id, notif.payload)
      end

      Repo.update!(ScheduledNotification.changeset(notif, %{status: :sent, sent_at: now}))
    end)

    {:ok, length(due)}
  end

  # -------------------------------------------------------------------
  # Delivery tracking and analytics
  # -------------------------------------------------------------------

  defp record_delivery(user_id, channel, result) do
    status = if match?({:ok, _}, result) or result == :ok, do: :delivered, else: :failed

    Repo.insert!(%DeliveryRecord{
      user_id: user_id,
      channel: channel,
      status:  status,
      sent_at: DateTime.utc_now()
    })
  end

  def delivery_stats(user_id, since) do
    records =
      from(d in DeliveryRecord,
        where: d.user_id == ^user_id and d.sent_at >= ^since
      )
      |> Repo.all()

    Enum.group_by(records, & &1.channel)
    |> Map.new(fn {channel, entries} ->
      delivered = Enum.count(entries, &(&1.status == :delivered))
      failed    = Enum.count(entries, &(&1.status == :failed))
      {channel, %{delivered: delivered, failed: failed, total: length(entries)}}
    end)
  end
end
# VALIDATION: SMELL END
```
