# Annotated Example — Speculative Generality

## Metadata

- **Smell name:** Speculative Generality
- **Expected smell location:** `build_rich_payload/2` in `Notifications.PushDispatcher`
- **Affected function(s):** `build_rich_payload/2`
- **Short explanation:** `build_rich_payload/2` was written speculatively to support rich push notifications containing images and action buttons, but no caller in the system ever invokes it. The dispatcher always uses `build_simple_payload/1` for every outbound notification. The rich-payload function is dead code that inflates the module without providing value.

---

```elixir
defmodule Notifications.PushDispatcher do
  @moduledoc """
  Dispatches push notifications to iOS and Android devices via
  the configured push gateway (APNs / FCM).

  Each notification is built into a provider-specific payload,
  enqueued to the outbound delivery queue, and tracked in the
  notification log for delivery reporting.
  """

  require Logger

  alias Notifications.{DeviceToken, NotificationLog, DeliveryQueue}

  @max_title_length 65
  @max_body_length 240
  @default_sound "default"
  @default_badge nil

  @spec dispatch(String.t(), String.t(), String.t()) ::
          {:ok, String.t()} | {:error, atom()}
  def dispatch(user_id, title, body) do
    with {:ok, tokens} <- DeviceToken.list_active(user_id),
         :ok <- validate_payload_lengths(title, body),
         {:ok, log_id} <- NotificationLog.create(user_id, title, body) do
      payloads =
        Enum.map(tokens, fn token ->
          payload = build_simple_payload(title, body, token.platform)
          %{token: token.value, platform: token.platform, payload: payload, log_id: log_id}
        end)

      case DeliveryQueue.enqueue_batch(payloads) do
        :ok ->
          Logger.info("Enqueued #{length(payloads)} push(es) for user=#{user_id} log=#{log_id}")
          {:ok, log_id}

        {:error, reason} ->
          Logger.error("Failed to enqueue push for user=#{user_id}: #{inspect(reason)}")
          {:error, :enqueue_failed}
      end
    end
  end

  defp build_simple_payload(title, body, :ios) do
    %{
      aps: %{
        alert: %{title: truncate(title, @max_title_length), body: truncate(body, @max_body_length)},
        sound: @default_sound,
        badge: @default_badge
      }
    }
  end

  defp build_simple_payload(title, body, :android) do
    %{
      notification: %{
        title: truncate(title, @max_title_length),
        body: truncate(body, @max_body_length)
      },
      android: %{priority: "high"}
    }
  end

  defp build_simple_payload(title, body, _platform) do
    %{title: truncate(title, @max_title_length), body: truncate(body, @max_body_length)}
  end

  # VALIDATION: SMELL START - Speculative Generality
  # VALIDATION: This is a smell because `build_rich_payload/2` is never called 
  # anywhere in this module or the broader codebase. It was written speculatively 
  # to support rich notifications with images and action buttons for a future 
  # feature that was never built. The function adds maintenance burden and code 
  # noise without contributing to any real behaviour.
  defp build_rich_payload(%{title: title, body: body, image_url: image_url}, platform) do
    base = build_simple_payload(title, body, platform)

    case platform do
      :ios ->
        put_in(base, [:aps, :mutable_content], 1)
        |> put_in([:aps, :media_url], image_url)

      :android ->
        put_in(base, [:notification, :image], image_url)
    end
  end
  # VALIDATION: SMELL END

  defp validate_payload_lengths(title, body) do
    cond do
      String.length(title) == 0 -> {:error, :empty_title}
      String.length(body) == 0 -> {:error, :empty_body}
      true -> :ok
    end
  end

  defp truncate(string, max_length) do
    if String.length(string) > max_length do
      String.slice(string, 0, max_length - 1) <> "…"
    else
      string
    end
  end
end
```
