# Annotated Example 07

## Metadata

- **Smell name:** Accessing non-existent Map/Struct fields
- **Expected smell location:** `Notifications.Dispatcher.build_payload/2`, lines where `template` map keys are accessed dynamically
- **Affected function(s):** `build_payload/2`
- **Short explanation:** `template[:subject]`, `template[:body]`, and `template[:locale]` use dynamic bracket access on a plain map. If any of these keys are absent the function silently receives `nil` and continues building a notification payload, making it impossible to distinguish a missing key from one that was deliberately set to `nil`.

---

```elixir
defmodule Notifications.Dispatcher do
  @moduledoc """
  Responsible for building and dispatching notifications (email, SMS, push)
  to end users based on event types and configurable templates.
  """

  require Logger

  @supported_channels [:email, :sms, :push]

  @spec dispatch(String.t(), map(), map()) :: :ok | {:error, term()}
  def dispatch(event_type, recipient, context \\ %{}) do
    with {:ok, template} <- fetch_template(event_type, recipient.locale),
         {:ok, payload}  <- build_payload(template, context),
         :ok             <- send_notification(recipient, payload) do
      Logger.info("Notification dispatched",
        event: event_type,
        recipient_id: recipient.id,
        channel: payload.channel
      )

      :ok
    else
      {:error, reason} ->
        Logger.error("Failed to dispatch notification",
          event: event_type,
          recipient_id: recipient.id,
          reason: inspect(reason)
        )

        {:error, reason}
    end
  end

  @spec build_payload(map(), map()) :: {:ok, map()} | {:error, term()}
  def build_payload(template, context) do
    # VALIDATION: SMELL START - Accessing non-existent Map/Struct fields
    # VALIDATION: This is a smell because `template[:subject]`,
    # `template[:body]`, and `template[:locale]` use dynamic bracket access.
    # If `:subject` or `:body` is absent, `nil` is interpolated silently into
    # the rendered strings. The caller cannot distinguish a template that
    # intentionally has `subject: nil` from one that simply lacks the key,
    # masking configuration errors.
    subject = template[:subject]
    body    = template[:body]
    locale  = template[:locale]
    # VALIDATION: SMELL END

    rendered_subject = interpolate(subject, context)
    rendered_body    = interpolate(body, context)

    channel = resolve_channel(template)

    {:ok,
     %{
       channel: channel,
       locale: locale,
       subject: rendered_subject,
       body: rendered_body,
       sent_at: nil
     }}
  rescue
    e ->
      {:error, {:render_failed, Exception.message(e)}}
  end

  @spec fetch_template(String.t(), String.t()) :: {:ok, map()} | {:error, :template_not_found}
  defp fetch_template(event_type, locale) do
    templates = load_templates()

    key = "#{event_type}_#{locale}"
    fallback_key = "#{event_type}_en"

    case Map.get(templates, key) || Map.get(templates, fallback_key) do
      nil      -> {:error, :template_not_found}
      template -> {:ok, template}
    end
  end

  @spec resolve_channel(map()) :: atom()
  defp resolve_channel(template) do
    channel = Map.get(template, :channel, :email)

    if channel in @supported_channels do
      channel
    else
      :email
    end
  end

  @spec send_notification(map(), map()) :: :ok | {:error, term()}
  defp send_notification(recipient, %{channel: :email} = payload) do
    Logger.debug("Sending email to #{recipient.email}")
    # Simulate sending – replace with real mailer adapter in production
    :ok
  end

  defp send_notification(recipient, %{channel: :sms} = payload) do
    Logger.debug("Sending SMS to #{recipient.phone}")
    :ok
  end

  defp send_notification(recipient, %{channel: :push} = payload) do
    Logger.debug("Sending push to device #{recipient.device_token}")
    :ok
  end

  @spec interpolate(String.t() | nil, map()) :: String.t()
  defp interpolate(nil, _context), do: ""
  defp interpolate(template_str, context) do
    Enum.reduce(context, template_str, fn {key, value}, acc ->
      String.replace(acc, "{{#{key}}}", to_string(value))
    end)
  end

  @spec load_templates() :: map()
  defp load_templates do
    %{
      "user_welcome_en" => %{
        channel: :email,
        locale: "en",
        subject: "Welcome, {{name}}!",
        body: "Hi {{name}}, your account is ready."
      },
      "password_reset_en" => %{
        channel: :email,
        locale: "en",
        subject: "Reset your password",
        body: "Click here to reset: {{reset_link}}"
      }
    }
  end
end
```
