# Annotated Example – Bad Code (Feature Envy)

## Metadata

| Field | Value |
|---|---|
| **Smell** | Feature Envy |
| **Expected Smell Location** | `Notifications.AlertComposer.compose_push_payload/1` |
| **Affected Function(s)** | `compose_push_payload/1` |
| **Explanation** | `compose_push_payload/1` lives in `Notifications.AlertComposer` but performs all its work on `Notifications.DeviceProfile` — calling `get!/1`, `push_enabled?/1`, `preferred_locale/1`, `badge_count/1`, and reading struct fields. The function contributes nothing from its own module's context and should be moved to `DeviceProfile`. |

```elixir
defmodule Notifications.DeviceProfile do
  @moduledoc "Represents a registered device for push notifications."

  defstruct [
    :id,
    :user_id,
    :device_token,
    :platform,
    :app_version,
    :locale,
    :timezone,
    :push_enabled,
    :unread_count,
    :last_seen_at,
    :notification_sound
  ]

  def get!(id) do
    %__MODULE__{
      id: id,
      user_id: "USR-888",
      device_token: "apns_token_abc123",
      platform: :ios,
      app_version: "4.2.1",
      locale: "en-US",
      timezone: "America/New_York",
      push_enabled: true,
      unread_count: 5,
      last_seen_at: ~U[2024-03-14 11:30:00Z],
      notification_sound: "chime.wav"
    }
  end

  def push_enabled?(%__MODULE__{push_enabled: true}), do: true
  def push_enabled?(_), do: false

  def preferred_locale(%__MODULE__{locale: locale}), do: locale

  def badge_count(%__MODULE__{unread_count: n}), do: n + 1

  def sound(%__MODULE__{notification_sound: s}), do: s

  def apns?(%__MODULE__{platform: :ios}), do: true
  def apns?(_), do: false
end

defmodule Notifications.Template do
  @moduledoc "Resolves localised notification templates."

  def resolve(:order_shipped, "en-US"), do: %{title: "Your order shipped!", body: "Track it now."}
  def resolve(:order_shipped, "es-MX"), do: %{title: "¡Tu pedido fue enviado!", body: "Rastréalo ahora."}
  def resolve(:order_shipped, _),       do: %{title: "Order shipped", body: "Track your order."}
  def resolve(:payment_due, "en-US"),   do: %{title: "Payment reminder", body: "Your payment is due soon."}
  def resolve(:payment_due, _),         do: %{title: "Payment reminder", body: "Payment due soon."}
end

defmodule Notifications.AlertComposer do
  @moduledoc """
  Composes structured push notification payloads ready for delivery
  to Apple APNs or Google FCM.
  """

  alias Notifications.{DeviceProfile, Template}
  require Logger

  @doc """
  Sends a push notification of `event_type` to the device identified by `device_id`.
  """
  def send_alert(device_id, event_type) do
    device = DeviceProfile.get!(device_id)

    if DeviceProfile.push_enabled?(device) do
      payload = compose_push_payload(device_id, event_type)
      deliver(device, payload)
    else
      Logger.debug("Push suppressed for device #{device_id}: push disabled")
      {:ok, :suppressed}
    end
  end

  defp deliver(%DeviceProfile{platform: :ios} = device, payload) do
    Logger.info("APNs delivery to #{device.device_token}")
    {:ok, %{gateway: :apns, token: device.device_token, payload: payload}}
  end

  defp deliver(%DeviceProfile{platform: :android} = device, payload) do
    Logger.info("FCM delivery to #{device.device_token}")
    {:ok, %{gateway: :fcm, token: device.device_token, payload: payload}}
  end

  defp deliver(device, _payload) do
    {:error, {:unsupported_platform, device.platform}}
  end

  # VALIDATION: SMELL START - Feature Envy
  # VALIDATION: This is a smell because `compose_push_payload/2` is defined in
  # VALIDATION: `AlertComposer` yet all operations target `DeviceProfile`:
  # VALIDATION: it calls `DeviceProfile.get!/1`, `DeviceProfile.push_enabled?/1`,
  # VALIDATION: `DeviceProfile.preferred_locale/1`, `DeviceProfile.badge_count/1`,
  # VALIDATION: and `DeviceProfile.sound/1`. The function reads its own module's
  # VALIDATION: state nowhere and should be moved into `DeviceProfile`.
  defp compose_push_payload(device_id, event_type) do
    device  = DeviceProfile.get!(device_id)
    locale  = DeviceProfile.preferred_locale(device)
    badge   = DeviceProfile.badge_count(device)
    sound   = DeviceProfile.sound(device)
    enabled = DeviceProfile.push_enabled?(device)

    template = Template.resolve(event_type, locale)

    %{
      title:   template.title,
      body:    template.body,
      badge:   badge,
      sound:   sound,
      enabled: enabled,
      locale:  locale,
      data: %{
        event: event_type,
        device_id: device.id,
        user_id: device.user_id
      }
    }
  end
  # VALIDATION: SMELL END
end
```
