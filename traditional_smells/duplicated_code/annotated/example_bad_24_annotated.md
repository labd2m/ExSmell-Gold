# Annotated Example — Duplicated Code

## Metadata

- **Smell name:** Duplicated Code
- **Expected smell location:** `NotificationDispatcher.send_email/2` and `NotificationDispatcher.send_sms/2`
- **Affected functions:** `send_email/2`, `send_sms/2`
- **Short explanation:** Both delivery functions independently build the recipient's full name, resolve the locale, and interpolate the message template. This formatting pipeline is duplicated instead of being shared.

---

```elixir
defmodule NotificationDispatcher do
  @moduledoc """
  Dispatches notifications via email, SMS, and push channels for user-facing events.
  """

  alias Notifications.{Template, Recipient, EmailAdapter, SmsAdapter, PushAdapter, AuditLog}

  @fallback_locale "en"
  @supported_locales ~w(en es fr de pt)

  def send_email(event, recipient_id) do
    with {:ok, recipient} <- Recipient.fetch(recipient_id),
         {:ok, template} <- Template.fetch(event, :email) do

      # VALIDATION: SMELL START - Duplicated Code
      # VALIDATION: This is a smell because the logic to assemble the full name,
      # determine the effective locale, and interpolate the template body is
      # reproduced identically in `send_sms/2` below.
      full_name =
        [recipient.first_name, recipient.last_name]
        |> Enum.reject(&is_nil/1)
        |> Enum.map(&String.trim/1)
        |> Enum.join(" ")

      locale =
        if recipient.locale in @supported_locales,
          do: recipient.locale,
          else: @fallback_locale

      body =
        template.bodies
        |> Map.get(locale, Map.fetch!(template.bodies, @fallback_locale))
        |> String.replace("{{name}}", full_name)
        |> String.replace("{{event}}", to_string(event))
      # VALIDATION: SMELL END

      subject = template.subjects[locale] || template.subjects[@fallback_locale]

      payload = %{
        to: recipient.email,
        subject: subject,
        body: body,
        from: "noreply@app.example.com",
        reply_to: "support@app.example.com"
      }

      case EmailAdapter.deliver(payload) do
        :ok ->
          AuditLog.record(:email_sent, recipient_id, event)
          :ok

        {:error, reason} ->
          AuditLog.record(:email_failed, recipient_id, event, reason)
          {:error, reason}
      end
    end
  end

  def send_sms(event, recipient_id) do
    with {:ok, recipient} <- Recipient.fetch(recipient_id),
         {:ok, template} <- Template.fetch(event, :sms),
         true <- not is_nil(recipient.phone_number) do

      # VALIDATION: SMELL START - Duplicated Code
      # VALIDATION: This is a smell because the name assembly, locale selection,
      # and template interpolation block duplicates the one in `send_email/2`.
      # Any change to how names or locales are handled must be made in both places.
      full_name =
        [recipient.first_name, recipient.last_name]
        |> Enum.reject(&is_nil/1)
        |> Enum.map(&String.trim/1)
        |> Enum.join(" ")

      locale =
        if recipient.locale in @supported_locales,
          do: recipient.locale,
          else: @fallback_locale

      body =
        template.bodies
        |> Map.get(locale, Map.fetch!(template.bodies, @fallback_locale))
        |> String.replace("{{name}}", full_name)
        |> String.replace("{{event}}", to_string(event))
      # VALIDATION: SMELL END

      payload = %{
        to: recipient.phone_number,
        body: body
      }

      case SmsAdapter.deliver(payload) do
        :ok ->
          AuditLog.record(:sms_sent, recipient_id, event)
          :ok

        {:error, reason} ->
          AuditLog.record(:sms_failed, recipient_id, event, reason)
          {:error, reason}
      end
    else
      false -> {:error, :no_phone_number}
      error -> error
    end
  end

  def send_push(event, recipient_id) do
    with {:ok, recipient} <- Recipient.fetch(recipient_id),
         {:ok, template} <- Template.fetch(event, :push),
         {:ok, device_tokens} <- Recipient.device_tokens(recipient_id),
         false <- Enum.empty?(device_tokens) do

      results =
        Enum.map(device_tokens, fn token ->
          payload = %{
            token: token,
            title: template.title,
            body: template.short_body
          }

          PushAdapter.deliver(payload)
        end)

      if Enum.all?(results, &(&1 == :ok)) do
        AuditLog.record(:push_sent, recipient_id, event)
        :ok
      else
        {:partial, results}
      end
    else
      true -> {:error, :no_device_tokens}
      error -> error
    end
  end
end
```
