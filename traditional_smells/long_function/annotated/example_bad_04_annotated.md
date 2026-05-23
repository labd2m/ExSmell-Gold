# Annotated Example — Long Function

## Metadata

- **Smell name:** Long Function
- **Expected smell location:** `Notifications.Dispatcher.dispatch/2`
- **Affected function(s):** `dispatch/2`
- **Short explanation:** The `dispatch/2` function handles preference lookup, channel routing, message template rendering, rate-limit checking, delivery via multiple channels, and result logging all inline. Each channel's delivery logic is embedded in the same body, making the function exceed any reasonable size and responsibility boundary.

---

```elixir
defmodule Notifications.Dispatcher do
  @moduledoc """
  Routes and delivers notifications to users across email, SMS, and push channels
  based on user preferences and rate limits.
  """

  alias Notifications.{Preference, RateLimiter, Template, DeliveryLog, Repo}
  alias Integrations.{Mailer, SmsGateway, PushService}
  require Logger

  @rate_limit_window_seconds 3600
  @max_notifications_per_hour 10

  # VALIDATION: SMELL START - Long Function
  # VALIDATION: This is a smell because `dispatch/2` packs preference loading,
  # VALIDATION: rate-limit enforcement, template rendering, and per-channel delivery
  # VALIDATION: (email, SMS, push) plus logging all into one function body that
  # VALIDATION: is far too long and has too many distinct concerns.
  def dispatch(user_id, %{type: type, payload: payload} = notification) do
    Logger.info("Dispatching notification type=#{type} to user=#{user_id}")

    # --- Load preferences ---
    preferences =
      case Repo.get_by(Preference, user_id: user_id) do
        nil  -> %{email: true, sms: false, push: true}
        pref -> Map.take(pref, [:email, :sms, :push])
      end

    # --- Rate limit check ---
    window_start = DateTime.add(DateTime.utc_now(), -@rate_limit_window_seconds, :second)

    recent_count =
      DeliveryLog
      |> DeliveryLog.for_user(user_id)
      |> DeliveryLog.since(window_start)
      |> Repo.aggregate(:count, :id)

    if recent_count >= @max_notifications_per_hour do
      Logger.warning("Rate limit reached for user #{user_id}, dropping notification #{type}")
      {:error, :rate_limited}
    else
      # --- Render template ---
      {:ok, rendered} = Template.render(type, payload)

      results = []

      # --- Email channel ---
      results =
        if preferences[:email] do
          case Mailer.deliver(%{
                 to: payload[:email],
                 subject: rendered.subject,
                 html_body: rendered.html,
                 text_body: rendered.text
               }) do
            {:ok, ref} ->
              Repo.insert!(DeliveryLog.changeset(%DeliveryLog{}, %{
                user_id: user_id,
                channel: :email,
                notification_type: type,
                status: :delivered,
                external_ref: ref
              }))
              [{:email, :ok} | results]

            {:error, reason} ->
              Logger.error("Email delivery failed for user #{user_id}: #{inspect(reason)}")
              [{:email, {:error, reason}} | results]
          end
        else
          results
        end

      # --- SMS channel ---
      results =
        if preferences[:sms] && Map.has_key?(payload, :phone) do
          case SmsGateway.send(%{to: payload[:phone], body: rendered.sms_body}) do
            {:ok, sid} ->
              Repo.insert!(DeliveryLog.changeset(%DeliveryLog{}, %{
                user_id: user_id,
                channel: :sms,
                notification_type: type,
                status: :delivered,
                external_ref: sid
              }))
              [{:sms, :ok} | results]

            {:error, reason} ->
              Logger.error("SMS delivery failed for user #{user_id}: #{inspect(reason)}")
              [{:sms, {:error, reason}} | results]
          end
        else
          results
        end

      # --- Push channel ---
      results =
        if preferences[:push] && Map.has_key?(payload, :device_token) do
          case PushService.notify(%{
                 token: payload[:device_token],
                 title: rendered.push_title,
                 body: rendered.push_body,
                 data: %{type: type}
               }) do
            {:ok, _} ->
              Repo.insert!(DeliveryLog.changeset(%DeliveryLog{}, %{
                user_id: user_id,
                channel: :push,
                notification_type: type,
                status: :delivered,
                external_ref: nil
              }))
              [{:push, :ok} | results]

            {:error, reason} ->
              Logger.error("Push delivery failed for user #{user_id}: #{inspect(reason)}")
              [{:push, {:error, reason}} | results]
          end
        else
          results
        end

      {:ok, results}
    end
  end
  # VALIDATION: SMELL END
end
```
