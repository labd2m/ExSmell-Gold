```elixir
defmodule MyApp.NotificationDispatcher do
  @moduledoc """
  Dispatches outbound notifications via email, SMS, and push channels.
  Also handles notification logging and retry for failed deliveries.
  """

  alias MyApp.Repo
  alias MyApp.Schemas.NotificationLog
  alias MyApp.Integrations.{SendGrid, Twilio, Expo}
  import Ecto.Query



  @doc """
  Sends a transactional email using the configured email provider.
  """
  def send_email(to, template_id, params) when is_binary(to) do
    payload = %{
      to: [%{email: to}],
      template_id: template_id,
      dynamic_template_data: params
    }

    case SendGrid.send_mail(payload) do
      {:ok, _response} ->
        log_notification(:email, to, :delivered)
        :ok

      {:error, reason} ->
        log_notification(:email, to, :failed)
        {:error, reason}
    end
  end


  @doc """
  Sends an SMS message to the given phone number via Twilio.
  """
  def send_sms(phone_number, message) when is_binary(phone_number) do
    sanitized = String.replace(phone_number, ~r/[^\d+]/, "")

    if String.length(sanitized) < 10 do
      {:error, :invalid_phone_number}
    else
      case Twilio.send_message(%{to: sanitized, body: message}) do
        {:ok, %{sid: sid}} ->
          log_notification(:sms, phone_number, :delivered, %{sid: sid})
          :ok

        {:error, reason} ->
          log_notification(:sms, phone_number, :failed)
          {:error, reason}
      end
    end
  end


  @doc """
  Sends a push notification to a device identified by its Expo push token.
  """
  def send_push(expo_token, title, body, data \\ %{}) do
    payload = %{
      to: expo_token,
      title: title,
      body: body,
      data: data,
      sound: "default",
      badge: 1
    }

    case Expo.send_push_notification(payload) do
      {:ok, %{status: "ok"}} ->
        log_notification(:push, expo_token, :delivered)
        :ok

      {:ok, %{status: "error", message: msg}} ->
        log_notification(:push, expo_token, :failed, %{error: msg})
        {:error, msg}

      {:error, reason} ->
        log_notification(:push, expo_token, :failed)
        {:error, reason}
    end
  end


  @doc """
  Persists a notification delivery attempt to the audit log.
  """
  def log_notification(channel, recipient, status, meta \\ %{}) do
    %NotificationLog{}
    |> NotificationLog.changeset(%{
      channel: channel,
      recipient: recipient,
      status: status,
      meta: meta,
      sent_at: DateTime.utc_now()
    })
    |> Repo.insert()
  end


  @doc """
  Retries all failed notifications from the past hour.
  """
  def retry_failed(limit \\ 50) do
    cutoff = DateTime.add(DateTime.utc_now(), -3600, :second)

    failed =
      from(n in NotificationLog,
        where: n.status == :failed and n.sent_at >= ^cutoff,
        limit: ^limit,
        order_by: [asc: n.sent_at]
      )
      |> Repo.all()

    Enum.each(failed, fn log ->
      case log.channel do
        :email -> send_email(log.recipient, log.meta["template_id"], log.meta["params"] || %{})
        :sms -> send_sms(log.recipient, log.meta["message"] || "")
        :push -> send_push(log.recipient, log.meta["title"] || "", log.meta["body"] || "")
      end
    end)

    {:ok, length(failed)}
  end

end
```
