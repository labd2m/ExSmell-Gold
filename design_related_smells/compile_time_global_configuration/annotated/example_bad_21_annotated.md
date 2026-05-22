# Annotated Bad Example 21

## Metadata

- **Smell name:** Compile-time global configuration
- **Expected smell location:** Module attribute `@fcm_server_key` defined at the top of `Notifications.PushDispatcher`
- **Affected function(s):** `send_to_device/3`, `send_to_topic/3`, `send_multicast/3`
- **Short explanation:** `Application.fetch_env!/2` is called in the module body to assign the FCM server key to a module attribute. Module attributes are resolved at compile-time, before the `:notifications` Application Environment is available, which can trigger a compilation warning or `ArgumentError`.

---

```elixir
defmodule Notifications.PushDispatcher do
  @moduledoc """
  Sends Firebase Cloud Messaging (FCM) push notifications to Android devices,
  iOS devices (via APNs-FCM bridge), and topic-subscribed device groups.
  Supports both data-only payloads and notification+data payloads.
  """

  require Logger

  @fcm_endpoint "https://fcm.googleapis.com/fcm/send"
  @request_timeout_ms 8_000
  @max_multicast_recipients 500

  # VALIDATION: SMELL START - Compile-time global configuration
  # VALIDATION: This is a smell because Application.fetch_env!/2 is invoked in the
  # VALIDATION: module body to assign the FCM server key to a module attribute.
  # VALIDATION: Module attributes are evaluated during compilation; the :notifications
  # VALIDATION: application configuration may not yet be loaded at that point, causing
  # VALIDATION: Elixir to raise a warning or ArgumentError at compile-time.
  @fcm_server_key Application.fetch_env!(:notifications, :fcm_server_key)
  # VALIDATION: SMELL END

  @type device_token :: String.t()
  @type fcm_topic :: String.t()
  @type notification_payload :: %{
          title: String.t(),
          body: String.t(),
          icon: String.t() | nil,
          sound: String.t() | nil
        }
  @type data_payload :: %{String.t() => String.t()}
  @type push_result ::
          {:ok, %{message_id: String.t()}}
          | {:error, :invalid_registration | :not_registered | :quota_exceeded | :unavailable | term()}

  @doc """
  Sends a push notification to a single device identified by `token`.

  ## Parameters
    - `token` - FCM registration token for the target device.
    - `notification` - Map with `:title` and `:body`; `:icon` and `:sound` are optional.
    - `data` - Additional string key-value pairs delivered to the app.
  """
  @spec send_to_device(device_token(), notification_payload(), data_payload()) :: push_result()
  def send_to_device(token, notification, data \\ %{})
      when is_binary(token) and is_map(notification) do
    Logger.info("Sending push notification to device token=#{String.slice(token, 0, 12)}...")

    payload = %{
      to: token,
      notification: sanitise_notification(notification),
      data: data,
      priority: "high"
    }

    dispatch(payload)
  end

  @doc """
  Sends a push notification to all devices subscribed to `topic`.

  Topics must be pre-registered in the FCM console and follow the pattern
  `/topics/<name>`.

  ## Parameters
    - `topic` - FCM topic string, e.g. `"/topics/breaking_news"`.
    - `notification` - Notification payload map.
    - `data` - Additional data payload.
  """
  @spec send_to_topic(fcm_topic(), notification_payload(), data_payload()) :: push_result()
  def send_to_topic(topic, notification, data \\ %{})
      when is_binary(topic) and is_map(notification) do
    Logger.info("Sending push notification to topic=#{topic}")

    payload = %{
      to: topic,
      notification: sanitise_notification(notification),
      data: data
    }

    dispatch(payload)
  end

  @doc """
  Sends the same notification to up to #{@max_multicast_recipients} devices in one request.

  Automatically chunks the token list if it exceeds the FCM limit.

  ## Parameters
    - `tokens` - List of FCM registration tokens.
    - `notification` - Notification payload map.
    - `data` - Additional data payload.
  """
  @spec send_multicast([device_token()], notification_payload(), data_payload()) ::
          [{device_token(), push_result()}]
  def send_multicast(tokens, notification, data \\ %{})
      when is_list(tokens) and is_map(notification) do
    Logger.info("Sending multicast push to #{length(tokens)} devices")

    tokens
    |> Enum.chunk_every(@max_multicast_recipients)
    |> Enum.flat_map(fn batch ->
      payload = %{
        registration_ids: batch,
        notification: sanitise_notification(notification),
        data: data,
        priority: "high"
      }

      case dispatch(payload) do
        {:ok, result} ->
          Enum.map(batch, fn token -> {token, {:ok, result}} end)

        {:error, reason} ->
          Enum.map(batch, fn token -> {token, {:error, reason}} end)
      end
    end)
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp dispatch(payload) do
    body = Jason.encode!(payload)
    headers = [
      {"Authorization", "key=#{@fcm_server_key}"},
      {"Content-Type", "application/json"}
    ]

    case HTTPoison.post(@fcm_endpoint, body, headers, recv_timeout: @request_timeout_ms) do
      {:ok, %HTTPoison.Response{status_code: 200, body: resp_body}} ->
        handle_fcm_response(Jason.decode!(resp_body))

      {:ok, %HTTPoison.Response{status_code: 400}} ->
        {:error, :malformed_request}

      {:ok, %HTTPoison.Response{status_code: 401}} ->
        Logger.error("FCM authentication failed - check server key")
        {:error, :authentication_error}

      {:ok, %HTTPoison.Response{status_code: 429}} ->
        Logger.warning("FCM quota exceeded")
        {:error, :quota_exceeded}

      {:ok, %HTTPoison.Response{status_code: status}} when status in 500..599 ->
        {:error, :unavailable}

      {:error, %HTTPoison.Error{reason: reason}} ->
        Logger.error("FCM HTTP error reason=#{inspect(reason)}")
        {:error, reason}
    end
  end

  defp handle_fcm_response(%{"message_id" => id}), do: {:ok, %{message_id: id}}
  defp handle_fcm_response(%{"results" => [%{"error" => err} | _]}), do: {:error, normalise_fcm_error(err)}
  defp handle_fcm_response(%{"failure" => 0, "success" => _}), do: {:ok, %{message_id: "multicast"}}
  defp handle_fcm_response(resp), do: {:error, {:unexpected_response, resp}}

  defp normalise_fcm_error("InvalidRegistration"), do: :invalid_registration
  defp normalise_fcm_error("NotRegistered"), do: :not_registered
  defp normalise_fcm_error(other), do: {:fcm_error, other}

  defp sanitise_notification(%{title: title, body: body} = n) do
    %{
      title: String.slice(title, 0, 100),
      body: String.slice(body, 0, 200),
      icon: Map.get(n, :icon, "ic_notification"),
      sound: Map.get(n, :sound, "default")
    }
  end
end
```
