# Annotated Example 04 — Long Parameter List

## Metadata

- **Smell name:** Long Parameter List
- **Expected smell location:** `Notifications.Dispatcher.send_notification/10`
- **Affected function(s):** `send_notification/10`
- **Short explanation:** Ten positional parameters mix recipient identity, channel configuration, content, and delivery options in a single function signature. These concerns belong in typed structs or a single options map.

---

```elixir
defmodule Notifications.Dispatcher do
  @moduledoc """
  Routes and dispatches notifications across multiple channels (email, SMS, push).
  """

  require Logger

  alias Notifications.{
    EmailAdapter,
    SmsAdapter,
    PushAdapter,
    NotificationLog
  }

  @channels [:email, :sms, :push]
  @priorities [:low, :normal, :high, :critical]

  # VALIDATION: SMELL START - Long Parameter List
  # VALIDATION: This is a smell because the function takes 10 individual parameters.
  # VALIDATION: Recipient info, delivery channel config, content fields, and scheduling
  # VALIDATION: options are all flattened into a single positional list.
  def send_notification(
        recipient_id,
        recipient_email,
        recipient_phone,
        recipient_push_token,
        channel,
        subject,
        body,
        priority,
        scheduled_at,
        retry_on_failure
      ) do
    # VALIDATION: SMELL END

    with :ok <- validate_channel(channel),
         :ok <- validate_priority(priority),
         :ok <- validate_recipient_for_channel(channel, recipient_email, recipient_phone, recipient_push_token),
         :ok <- validate_content(subject, body) do

      payload = build_payload(channel, subject, body)
      log_entry = %NotificationLog{
        recipient_id: recipient_id,
        channel: channel,
        subject: subject,
        priority: priority,
        scheduled_at: scheduled_at,
        status: :pending,
        created_at: DateTime.utc_now()
      }

      dispatch_fn = dispatch_function(channel)

      target =
        case channel do
          :email -> recipient_email
          :sms -> recipient_phone
          :push -> recipient_push_token
        end

      result =
        if scheduled_at && DateTime.compare(scheduled_at, DateTime.utc_now()) == :gt do
          schedule_for_later(dispatch_fn, target, payload, scheduled_at)
        else
          dispatch_fn.(target, payload)
        end

      case result do
        :ok ->
          NotificationLog.save(%{log_entry | status: :sent})
          Logger.info("Notification sent to recipient #{recipient_id} via #{channel}")
          {:ok, log_entry}

        {:error, reason} when retry_on_failure ->
          Logger.warning("Notification failed, enqueuing retry: #{inspect(reason)}")
          enqueue_retry(dispatch_fn, target, payload, log_entry)

        {:error, reason} ->
          NotificationLog.save(%{log_entry | status: :failed})
          {:error, reason}
      end
    end
  end

  defp dispatch_function(:email), do: &EmailAdapter.send/2
  defp dispatch_function(:sms), do: &SmsAdapter.send/2
  defp dispatch_function(:push), do: &PushAdapter.send/2

  defp build_payload(:email, subject, body), do: %{subject: subject, body: body}
  defp build_payload(:sms, _subject, body), do: %{body: body}
  defp build_payload(:push, subject, body), do: %{title: subject, body: body}

  defp validate_channel(c) when c in @channels, do: :ok
  defp validate_channel(c), do: {:error, {:unsupported_channel, c}}

  defp validate_priority(p) when p in @priorities, do: :ok
  defp validate_priority(p), do: {:error, {:invalid_priority, p}}

  defp validate_content(subject, body)
       when is_binary(subject) and byte_size(subject) > 0 and
              is_binary(body) and byte_size(body) > 0,
       do: :ok

  defp validate_content(_, _), do: {:error, :missing_content}

  defp validate_recipient_for_channel(:email, nil, _, _), do: {:error, :missing_email}
  defp validate_recipient_for_channel(:sms, _, nil, _), do: {:error, :missing_phone}
  defp validate_recipient_for_channel(:push, _, _, nil), do: {:error, :missing_push_token}
  defp validate_recipient_for_channel(_, _, _, _), do: :ok

  defp schedule_for_later(_fn, _target, _payload, _at), do: :ok

  defp enqueue_retry(_fn, _target, _payload, _log), do: :ok
end
```
