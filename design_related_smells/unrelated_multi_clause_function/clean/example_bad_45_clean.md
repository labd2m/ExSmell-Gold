```elixir
defmodule MyApp.NotificationDispatcher do
  @moduledoc """
  Dispatcher for all outbound notifications, including transactional emails,
  in-app alerts, and SMS messages.
  """

  require Logger

  alias MyApp.Repo
  alias MyApp.Notifications.{EmailJob, InAppAlert, SmsMessage}
  alias MyApp.Integrations.{SendgridClient, TwilioClient}
  alias MyApp.Accounts.UserPreferences

  @sendgrid_from "noreply@myapp.io"
  @sms_sender_id "MYAPP"
  @alert_max_ttl_hours 72

  @doc """
  Dispatches a notification.

  Accepts an `%EmailJob{}`, an `%InAppAlert{}`, or an `%SmsMessage{}`.

  ## Examples

      iex> MyApp.NotificationDispatcher.dispatch(%EmailJob{template: :welcome, to: "user@example.com"})
      {:ok, :sent}

  """

  def dispatch(%EmailJob{
        template: template,
        to: to,
        locale: locale,
        params: params,
        idempotency_key: key
      } = job) do
    prefs = UserPreferences.get_by_email(to)

    if prefs && prefs.unsubscribed_email do
      Logger.info("Skipping email to #{to}: user unsubscribed")
      {:ok, :skipped}
    else
      {subject, html_body, text_body} = render_email_template(template, locale, params)

      payload = %{
        from: @sendgrid_from,
        to: to,
        subject: subject,
        html_body: html_body,
        text_body: text_body,
        custom_args: %{idempotency_key: key}
      }

      case SendgridClient.send(payload) do
        {:ok, %{message_id: msg_id}} ->
          Repo.update!(EmailJob.changeset(job, %{status: :sent, external_id: msg_id, sent_at: DateTime.utc_now()}))
          Logger.info("Email #{template} sent to #{to} [msg_id: #{msg_id}]")
          {:ok, :sent}

        {:error, :rate_limited} ->
          Logger.warn("Sendgrid rate limited, re-enqueuing email job #{job.id}")
          {:error, :rate_limited}

        {:error, reason} ->
          Logger.error("Email dispatch failed for #{to}: #{inspect(reason)}")
          Repo.update!(EmailJob.changeset(job, %{status: :failed}))
          {:error, reason}
      end
    end
  end

  def dispatch(%InAppAlert{
        user_id: user_id,
        kind: kind,
        title: title,
        body: body,
        action_url: action_url
      } = alert) do
    Logger.info("Creating in-app alert (#{kind}) for user #{user_id}")

    expires_at = DateTime.add(DateTime.utc_now(), @alert_max_ttl_hours * 3600, :second)

    case Repo.insert(
           InAppAlert.changeset(alert, %{
             read: false,
             expires_at: expires_at,
             created_at: DateTime.utc_now()
           })
         ) do
      {:ok, saved_alert} ->
        MyAppWeb.Endpoint.broadcast("user:#{user_id}", "new_alert", %{
          id: saved_alert.id,
          kind: kind,
          title: title,
          body: body,
          action_url: action_url
        })

        Logger.info("In-app alert #{saved_alert.id} broadcast to user #{user_id}")
        {:ok, :delivered}

      {:error, changeset} ->
        Logger.error("Failed to persist in-app alert: #{inspect(changeset.errors)}")
        {:error, :persistence_failed}
    end
  end

  def dispatch(%SmsMessage{
        to_number: to_number,
        body: body,
        kind: :two_factor,
        user_id: user_id
      } = sms) do
    Logger.info("Sending 2FA SMS to user #{user_id} at #{mask_number(to_number)}")

    if String.length(body) > 160 do
      Logger.error("SMS body exceeds 160 chars for user #{user_id}")
      {:error, :message_too_long}
    else
      case TwilioClient.send_sms(%{
             from: @sms_sender_id,
             to: to_number,
             body: body
           }) do
        {:ok, %{sid: sid}} ->
          Repo.update!(SmsMessage.changeset(sms, %{status: :sent, external_sid: sid, sent_at: DateTime.utc_now()}))
          Logger.info("2FA SMS sent to user #{user_id}, SID: #{sid}")
          {:ok, :sent}

        {:error, :invalid_number} ->
          Logger.warn("Invalid phone number for user #{user_id}: #{mask_number(to_number)}")
          {:error, :invalid_number}

        {:error, reason} ->
          Logger.error("SMS dispatch failed for user #{user_id}: #{inspect(reason)}")
          {:error, reason}
      end
    end
  end


  defp render_email_template(template, locale, params) do
    MyApp.Mailer.Templates.render(template, locale, params)
  end

  defp mask_number(number) do
    String.replace(number, ~r/\d(?=\d{4})/, "*")
  end
end
```
