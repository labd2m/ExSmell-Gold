# Code Smell: Accessing Non-Existent Map/Struct Fields

- **Smell name:** Accessing non-existent Map/Struct fields
- **Expected smell location:** `Notifications.Dispatcher.dispatch/1`, where channel preference flags are accessed dynamically
- **Affected function(s):** `dispatch/1`
- **Short explanation:** The function reads notification channel preferences with bracket access (`recipient[:email_enabled]`, `recipient[:sms_enabled]`, `recipient[:push_token]`). Absent keys silently return `nil`, making it impossible to tell whether a recipient has opted out of a channel or whether the preference was never set.

```elixir
defmodule Notifications.Dispatcher do
  @moduledoc """
  Dispatches notifications to recipients through one or more channels
  (email, SMS, push) based on each recipient's stored preferences.
  Supports templated messages and per-channel delivery tracking.
  """

  require Logger

  @max_retries 3

  @type recipient :: %{
          id: String.t(),
          name: String.t(),
          email: String.t(),
          phone: String.t(),
          optional(:email_enabled) => boolean(),
          optional(:sms_enabled) => boolean(),
          optional(:push_token) => String.t()
        }

  @type notification :: %{
          id: String.t(),
          template: atom(),
          subject: String.t(),
          body: String.t(),
          recipient: recipient(),
          priority: :low | :normal | :high | :critical
        }

  @type delivery_result :: %{
          notification_id: String.t(),
          recipient_id: String.t(),
          channels_attempted: [atom()],
          channels_succeeded: [atom()],
          channels_failed: [atom()],
          dispatched_at: DateTime.t()
        }

  @spec dispatch(notification()) :: {:ok, delivery_result()} | {:error, String.t()}
  def dispatch(%{recipient: recipient} = notification) do
    Logger.info("Dispatching notification=#{notification.id} to recipient=#{recipient.id}")

    channels = resolve_channels(recipient, notification.priority)

    if channels == [] do
      {:error, "no delivery channels available for recipient #{recipient.id}"}
    else
      results = Enum.map(channels, &deliver(notification, &1))
      build_result(notification, results)
    end
  end

  defp resolve_channels(recipient, priority) do
    # VALIDATION: SMELL START - Accessing non-existent Map/Struct fields
    # VALIDATION: This is a smell because `recipient[:email_enabled]`,
    # `recipient[:sms_enabled]`, and `recipient[:push_token]` use dynamic bracket
    # access on a plain map. When any of these keys is absent, the expression
    # silently returns `nil`. For boolean fields, `nil` is treated as falsy,
    # so a recipient without an `:email_enabled` key is handled identically to
    # one that explicitly disabled email — masking missing configuration.
    email_enabled = recipient[:email_enabled]
    sms_enabled   = recipient[:sms_enabled]
    push_token    = recipient[:push_token]
    # VALIDATION: SMELL END

    base_channels =
      []
      |> then(fn ch -> if email_enabled, do: [:email | ch], else: ch end)
      |> then(fn ch -> if sms_enabled, do: [:sms | ch], else: ch end)
      |> then(fn ch -> if push_token, do: [:push | ch], else: ch end)

    case priority do
      :critical -> Enum.uniq([:email, :sms] ++ base_channels)
      :high     -> Enum.uniq([:email] ++ base_channels)
      _         -> base_channels
    end
  end

  defp deliver(notification, :email) do
    Logger.debug("Sending email for notification=#{notification.id}")
    simulate_delivery(:email, 0.05)
  end

  defp deliver(notification, :sms) do
    Logger.debug("Sending SMS for notification=#{notification.id}")
    simulate_delivery(:sms, 0.08)
  end

  defp deliver(notification, :push) do
    Logger.debug("Sending push for notification=#{notification.id}")
    simulate_delivery(:push, 0.12)
  end

  defp simulate_delivery(channel, failure_rate) do
    if :rand.uniform() > failure_rate do
      {:ok, channel}
    else
      {:error, channel, "delivery provider returned 5xx"}
    end
  end

  defp build_result(notification, results) do
    succeeded = for {:ok, ch}       <- results, do: ch
    failed    = for {:error, ch, _} <- results, do: ch

    result = %{
      notification_id:     notification.id,
      recipient_id:        notification.recipient.id,
      channels_attempted:  succeeded ++ failed,
      channels_succeeded:  succeeded,
      channels_failed:     failed,
      dispatched_at:       DateTime.utc_now()
    }

    {:ok, result}
  end
end
```
