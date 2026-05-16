```elixir
defmodule Notifications.Dispatcher do
  @moduledoc """
  Dispatches transactional notifications (email, SMS, push) to end users.

  Reads per-user preferences and builds a normalized payload before
  handing off to the appropriate channel adapter.
  """

  alias Notifications.Adapters.{Email, SMS, Push}
  alias Notifications.RateLimiter

  @default_locale "en"
  @supported_channels ~w(email sms push)

  @doc """
  Main entry point. Looks up user preferences and routes the notification
  to the correct channel adapter.
  """
  def dispatch(user_id, event, context \\ %{}) do
    with {:ok, prefs}   <- fetch_preferences(user_id),
         {:ok, payload} <- build_payload(event, prefs),
         :ok            <- RateLimiter.check(user_id, prefs),
         :ok            <- send_via_channel(payload) do
      {:ok, payload}
    end
  end

  @doc """
  Constructs a normalized notification payload from a raw event and user prefs map.

  Expected keys in `prefs`:
    - `:channel`      — delivery channel (`"email"`, `"sms"`, `"push"`)
    - `:locale`       — BCP-47 language tag
    - `:quiet_hours`  — map `%{from: hour, to: hour}` or absent
  """
  def build_payload(event, prefs) do
    channel     = prefs[:channel]
    locale      = prefs[:locale]
    quiet_hours = prefs[:quiet_hours]

    effective_locale  = locale || @default_locale
    effective_channel =
      if channel in @supported_channels, do: channel, else: "email"

    if should_suppress?(quiet_hours) do
      {:error, :quiet_hours_active}
    else
      payload = %{
        channel:    effective_channel,
        locale:     effective_locale,
        event_type: event.type,
        subject:    translate(event.subject, effective_locale),
        body:       translate(event.body,    effective_locale),
        metadata:   Map.take(event, [:idempotency_key, :correlation_id]),
        sent_at:    DateTime.utc_now()
      }

      {:ok, payload}
    end
  end

  ## Private

  defp should_suppress?(nil), do: false
  defp should_suppress?(%{from: from_h, to: to_h}) do
    current_hour = DateTime.utc_now().hour
    current_hour >= from_h or current_hour < to_h
  end

  defp send_via_channel(%{channel: "email"} = payload), do: Email.send(payload)
  defp send_via_channel(%{channel: "sms"}   = payload), do: SMS.send(payload)
  defp send_via_channel(%{channel: "push"}  = payload), do: Push.send(payload)

  defp translate(text, _locale), do: text

  defp fetch_preferences(user_id) do
    # Simulated DB lookup
    prefs = %{
      channel: "email",
      locale: "pt-BR"
      # :quiet_hours deliberately absent for some users
    }

    if prefs, do: {:ok, prefs}, else: {:error, :not_found}
  end
end
```
