```elixir
defmodule NotificationCenter do
  @moduledoc """
  Unified notification hub: multi-channel delivery, scheduling, delivery
  logging, user preference management, and unsubscription handling.
  """

  require Logger
  alias Notifications.Repo
  alias Notifications.DeliveryLog
  alias Notifications.ScheduledNotification
  alias Notifications.UserPreference

  @push_ttl_seconds 86_400
  @sms_max_chars 160


  def send_email(user, template, assigns) do
    with {:ok, body} <- render_template(template, assigns),
         :ok <- check_preference(user.id, :email) do
      result =
        Mailer.deliver(%{
          to: user.email,
          subject: Map.fetch!(assigns, :subject),
          html_body: body
        })

      log_delivery(user.id, :email, result)
      result
    else
      {:error, :opted_out} ->
        Logger.debug("User #{user.id} has opted out of email notifications")
        {:error, :opted_out}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp render_template(template, assigns) do
    path = "priv/notification_templates/#{template}.html.eex"

    case File.read(path) do
      {:ok, raw} -> {:ok, EEx.eval_string(raw, assigns)}
      {:error, _} -> {:error, :template_not_found}
    end
  end


  def send_sms(user, message, opts \\ []) do
    truncated =
      if String.length(message) > @sms_max_chars do
        String.slice(message, 0, @sms_max_chars - 3) <> "..."
      else
        message
      end

    with :ok <- check_preference(user.id, :sms),
         {:ok, phone} <- fetch_phone_number(user, opts) do
      result = SMSGateway.send(phone, truncated)
      log_delivery(user.id, :sms, result)
      result
    end
  end

  defp fetch_phone_number(user, opts) do
    phone = Keyword.get(opts, :override_phone, user.phone)

    if is_binary(phone) and String.match?(phone, ~r/^\+\d{7,15}$/) do
      {:ok, phone}
    else
      {:error, :invalid_phone}
    end
  end


  def send_push(user, %{title: title, body: body} = payload) do
    with :ok <- check_preference(user.id, :push),
         token when not is_nil(token) <- user.push_token do
      apns_payload = %{
        aps: %{alert: %{title: title, body: body}},
        data: Map.get(payload, :data, %{}),
        ttl: @push_ttl_seconds
      }

      result = PushService.send(token, apns_payload)
      log_delivery(user.id, :push, result)
      result
    else
      nil -> {:error, :no_push_token}
      {:error, _} = err -> err
    end
  end


  def broadcast_in_app(topic, message) do
    Phoenix.PubSub.broadcast(MyApp.PubSub, "notifications:#{topic}", {:notification, message})
    Logger.debug("In-app notification broadcast on topic #{topic}")
    :ok
  end


  def schedule_notification(user_id, type, scheduled_at) do
    attrs = %{
      user_id: user_id,
      type: type,
      scheduled_at: scheduled_at,
      status: :pending
    }

    case Repo.insert(ScheduledNotification.changeset(%ScheduledNotification{}, attrs)) do
      {:ok, sn} ->
        Logger.info("Notification scheduled at #{scheduled_at} for user #{user_id}")
        {:ok, sn}

      {:error, cs} ->
        {:error, cs}
    end
  end

  def cancel_scheduled(scheduled_id) do
    case Repo.get(ScheduledNotification, scheduled_id) do
      nil ->
        {:error, :not_found}

      sn ->
        sn
        |> ScheduledNotification.changeset(%{status: :cancelled})
        |> Repo.update()
    end
  end


  def log_delivery(user_id, channel, result) do
    status = if match?({:ok, _}, result) or result == :ok, do: :delivered, else: :failed

    Repo.insert(
      DeliveryLog.changeset(%DeliveryLog{}, %{
        user_id: user_id,
        channel: channel,
        status: status,
        delivered_at: DateTime.utc_now()
      })
    )
  end


  def fetch_preferences(user_id) do
    case Repo.get_by(UserPreference, user_id: user_id) do
      nil ->
        %{email: true, sms: true, push: true}

      prefs ->
        Map.take(prefs, [:email, :sms, :push])
    end
  end

  def update_preferences(user_id, changes) do
    prefs =
      case Repo.get_by(UserPreference, user_id: user_id) do
        nil -> %UserPreference{user_id: user_id}
        existing -> existing
      end

    prefs
    |> UserPreference.changeset(Map.take(changes, [:email, :sms, :push]))
    |> Repo.insert_or_update()
  end

  defp check_preference(user_id, channel) do
    prefs = fetch_preferences(user_id)

    if Map.get(prefs, channel, true) do
      :ok
    else
      {:error, :opted_out}
    end
  end


  def unsubscribe(user_id, channel) do
    update_preferences(user_id, %{channel => false})
    Logger.info("User #{user_id} unsubscribed from #{channel} notifications")
    :ok
  end
end
```
