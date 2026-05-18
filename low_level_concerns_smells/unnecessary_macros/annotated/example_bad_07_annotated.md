# Annotated Example 07 — Unnecessary Macros

## Metadata

- **Smell name:** Unnecessary macros
- **Expected smell location:** `defmacro truncate/2` inside `Notifications.TextUtils`
- **Affected function(s):** `truncate/2`
- **Short explanation:** The macro truncates a string to a maximum length and appends an ellipsis — a runtime string manipulation with no AST or compile-time value. A plain function is the correct and simpler approach.

---

```elixir
defmodule Notifications.TextUtils do
  @moduledoc """
  Text manipulation utilities used across notification channels:
  push notifications, SMS, and in-app message previews.
  """

  @ellipsis "..."

  # VALIDATION: SMELL START - Unnecessary macros
  # VALIDATION: This is a smell because truncate/2 only checks string length
  # and slices a runtime binary. This is a purely runtime operation with no
  # compile-time aspect; a normal function would be equivalent and cleaner.
  defmacro truncate(text, max_length) do
    quote do
      value = unquote(text)
      limit = unquote(max_length)

      if String.length(value) <= limit do
        value
      else
        String.slice(value, 0, limit - String.length(unquote(@ellipsis))) <> unquote(@ellipsis)
      end
    end
  end
  # VALIDATION: SMELL END

  @doc """
  Strips all HTML tags from a string, leaving only plain text.
  Useful when converting email body content to SMS-safe text.
  """
  @spec strip_html(String.t()) :: String.t()
  def strip_html(html) when is_binary(html) do
    Regex.replace(~r/<[^>]+>/, html, "")
  end

  @doc """
  Normalises whitespace by collapsing consecutive spaces and trimming edges.
  """
  @spec normalise_whitespace(String.t()) :: String.t()
  def normalise_whitespace(text) when is_binary(text) do
    text
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  @doc """
  Formats a notification body for a given channel's character constraints.
  """
  @spec prepare_for_channel(String.t(), atom()) :: String.t()
  def prepare_for_channel(body, channel) do
    cleaned = body |> strip_html() |> normalise_whitespace()

    case channel do
      :sms -> cleaned
      :push -> cleaned
      :email -> cleaned
      _ -> cleaned
    end
  end
end

defmodule Notifications.PushDispatcher do
  @moduledoc """
  Builds and dispatches push notification payloads to registered devices.
  Enforces platform-specific title and body length limits.
  """

  require Notifications.TextUtils

  alias Notifications.TextUtils

  @apns_title_limit 50
  @apns_body_limit 178
  @fcm_title_limit 65
  @fcm_body_limit 240

  @doc """
  Builds an APNS-compatible push payload from raw notification data.
  """
  @spec build_apns_payload(map()) :: map()
  def build_apns_payload(%{title: title, body: body, data: data}) do
    %{
      aps: %{
        alert: %{
          title: TextUtils.truncate(title, @apns_title_limit),
          body: TextUtils.truncate(TextUtils.prepare_for_channel(body, :push), @apns_body_limit)
        },
        sound: "default",
        badge: 1
      },
      data: data
    }
  end

  @doc """
  Builds an FCM-compatible push payload from raw notification data.
  """
  @spec build_fcm_payload(map()) :: map()
  def build_fcm_payload(%{title: title, body: body, data: data}) do
    %{
      notification: %{
        title: TextUtils.truncate(title, @fcm_title_limit),
        body: TextUtils.truncate(TextUtils.prepare_for_channel(body, :push), @fcm_body_limit)
      },
      data: data
    }
  end

  @doc """
  Dispatches a notification to all registered tokens for a user.
  Returns a list of per-token dispatch results.
  """
  @spec dispatch(map(), list(map())) :: list(map())
  def dispatch(notification, device_tokens) do
    Enum.map(device_tokens, fn %{token: token, platform: platform} ->
      payload =
        case platform do
          :ios -> build_apns_payload(notification)
          :android -> build_fcm_payload(notification)
        end

      %{token: token, platform: platform, payload: payload, dispatched_at: DateTime.utc_now()}
    end)
  end
end
```
