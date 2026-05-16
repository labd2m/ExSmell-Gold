# Annotated Example — Code Smell Validation

## Metadata

- **Smell name:** Complex branching
- **Expected smell location:** `parse_push_response/2` function
- **Affected function(s):** `parse_push_response/2`
- **Short explanation:** The function is the sole interpreter for every possible HTTP response from a push notification delivery endpoint — accepted, partially delivered, invalid device tokens, unregistered devices, payload-too-large, topic mismatches, FCM/APNs errors, and server faults — all within one deeply nested `case`. This concentrates all response-handling responsibility in one place, producing high cyclomatic complexity and a single fragile point of failure.

---

```elixir
defmodule Notifications.PushNotificationClient do
  @moduledoc """
  HTTP client for the mobile push notification aggregation service.
  Handles single-device, multicast, and topic-based pushes for both
  APNs (Apple) and FCM (Firebase/Google) platforms via a unified API.
  """

  require Logger

  @base_url "https://push-gateway.notifications.io/v2"

  def send_to_device(device_token, platform, title, body, opts \\ []) do
    data = Keyword.get(opts, :data, %{})
    badge = Keyword.get(opts, :badge)
    sound = Keyword.get(opts, :sound, "default")
    ttl_seconds = Keyword.get(opts, :ttl_seconds, 86_400)
    priority = Keyword.get(opts, :priority, "high")
    idempotency_key = Keyword.get(opts, :idempotency_key, generate_key())

    payload = %{
      device_token: device_token,
      platform: platform,
      notification: %{
        title: title,
        body: body,
        badge: badge,
        sound: sound
      },
      data: data,
      ttl_seconds: ttl_seconds,
      priority: priority
    }

    case http_post("#{@base_url}/send", payload, build_headers(idempotency_key)) do
      {:ok, raw} ->
        parse_push_response(raw, %{token: device_token, platform: platform})

      {:error, :timeout} ->
        {:error, :push_gateway_timeout}

      {:error, reason} ->
        {:error, {:transport, reason}}
    end
  end

  def send_to_topic(topic, title, body, opts \\ []) do
    data = Keyword.get(opts, :data, %{})
    condition = Keyword.get(opts, :condition)
    idempotency_key = Keyword.get(opts, :idempotency_key, generate_key())

    payload = %{
      topic: topic,
      condition: condition,
      notification: %{title: title, body: body},
      data: data
    }

    case http_post("#{@base_url}/topic-send", payload, build_headers(idempotency_key)) do
      {:ok, raw} ->
        parse_push_response(raw, %{topic: topic})

      {:error, reason} ->
        {:error, {:transport, reason}}
    end
  end

  def multicast(device_tokens, platform, title, body, opts \\ []) do
    data = Keyword.get(opts, :data, %{})

    payload = %{
      device_tokens: device_tokens,
      platform: platform,
      notification: %{title: title, body: body},
      data: data
    }

    case http_post("#{@base_url}/multicast", payload, build_headers()) do
      {:ok, %{status: 200, body: %{"success_count" => s, "failure_count" => f, "results" => r}}} ->
        {:ok, %{success_count: s, failure_count: f, results: r}}

      {:ok, %{status: status}} ->
        {:error, {:unexpected_status, status}}

      {:error, reason} ->
        {:error, {:transport, reason}}
    end
  end

  # VALIDATION: SMELL START - Complex branching
  # VALIDATION: This is a smell because `parse_push_response/2` is the sole
  # function handling every possible HTTP status and body variant returned by the
  # push notification send endpoint. The 200 path branches on queued (with and
  # without delivery estimate), immediately delivered, and rate-throttled-but-
  # queued body shapes. The 400 path branches on invalid_device_token,
  # unregistered_device, payload_too_large, invalid_topic, topic_mismatch,
  # invalid_notification_payload, and generic errors. Additional arms handle
  # APNs-specific credential failures (403), upstream FCM errors (502), and two
  # server error shapes. Every arm depends on different body keys, making the
  # function very long and dangerous: a MatchError in any one arm collapses the
  # entire function for all callers.
  defp parse_push_response(response, context) do
    case response do
      %{status: 200, body: body} ->
        case body do
          %{
            "status" => "queued",
            "message_id" => mid,
            "estimated_delivery_ms" => eta
          } ->
            {:ok,
             %{
               message_id: mid,
               status: :queued,
               estimated_delivery_ms: eta,
               delivered_at: nil
             }}

          %{"status" => "queued", "message_id" => mid} ->
            {:ok, %{message_id: mid, status: :queued, estimated_delivery_ms: nil, delivered_at: nil}}

          %{
            "status" => "delivered",
            "message_id" => mid,
            "delivered_at" => ts,
            "latency_ms" => lat
          } ->
            {:ok, %{message_id: mid, status: :delivered, delivered_at: ts, latency_ms: lat}}

          %{"status" => "delivered", "message_id" => mid, "delivered_at" => ts} ->
            {:ok, %{message_id: mid, status: :delivered, delivered_at: ts, latency_ms: nil}}

          %{
            "status" => "throttled_queued",
            "message_id" => mid,
            "queue_delay_seconds" => delay
          } ->
            Logger.warning("Push throttled context=#{inspect(context)} delay=#{delay}s")
            {:ok, %{message_id: mid, status: :throttled_queued, queue_delay_seconds: delay}}

          %{"status" => unknown} ->
            {:error, {:unknown_push_status, unknown}}

          _ ->
            {:error, :malformed_push_body}
        end

      %{status: 202, body: %{"message_id" => mid}} ->
        {:ok, %{message_id: mid, status: :accepted}}

      %{status: 400, body: body} ->
        case body do
          %{"error" => "invalid_device_token", "token" => token} ->
            {:error, {:invalid_device_token, token}}

          %{"error" => "unregistered_device", "token" => token} ->
            Logger.info("Unregistered device token=#{token} — should remove from DB")
            {:error, {:unregistered_device, token}}

          %{"error" => "payload_too_large", "max_bytes" => max, "actual_bytes" => actual} ->
            {:error, {:payload_too_large, max, actual}}

          %{"error" => "invalid_topic", "topic" => topic} ->
            {:error, {:invalid_topic, topic}}

          %{"error" => "topic_mismatch", "expected_platform" => plat} ->
            {:error, {:topic_mismatch, plat}}

          %{"error" => "invalid_notification_payload", "field" => field} ->
            {:error, {:invalid_notification_payload, field}}

          %{"error" => "ttl_too_large", "max_ttl" => max} ->
            {:error, {:ttl_too_large, max}}

          %{"error" => msg} ->
            {:error, {:bad_request, msg}}

          _ ->
            {:error, :bad_request}
        end

      %{status: 401} ->
        Logger.error("Push gateway unauthorized context=#{inspect(context)}")
        {:error, :unauthorized}

      %{status: 403, body: %{"error" => "apns_certificate_expired", "expired_at" => ts}} ->
        Logger.error("APNs certificate expired at=#{ts}")
        {:error, {:apns_certificate_expired, ts}}

      %{status: 403, body: %{"error" => "fcm_server_key_invalid"}} ->
        Logger.error("FCM server key invalid")
        {:error, :fcm_server_key_invalid}

      %{status: 403} ->
        {:error, :forbidden}

      %{status: 429, body: %{"retry_after" => sec, "device_quota_reset_at" => reset}} ->
        {:error, {:device_rate_limited, sec, reset}}

      %{status: 429, body: %{"retry_after" => sec}} ->
        {:error, {:rate_limited, sec}}

      %{status: 429} ->
        {:error, :rate_limited}

      %{status: 500, body: %{"request_id" => rid}} ->
        Logger.error("Push gateway 500 request_id=#{rid} context=#{inspect(context)}")
        {:error, {:server_error, rid}}

      %{status: 500} ->
        {:error, :server_error}

      %{status: 502, body: %{"upstream" => "apns", "apns_error" => err}} ->
        {:error, {:apns_upstream_error, err}}

      %{status: 502, body: %{"upstream" => "fcm", "fcm_error" => err}} ->
        {:error, {:fcm_upstream_error, err}}

      %{status: 502} ->
        {:error, :bad_gateway}

      %{status: 503} ->
        {:error, :service_unavailable}

      %{status: status, body: body} ->
        Logger.warning("Unhandled push status=#{status} body=#{inspect(body)}")
        {:error, {:unexpected_response, status}}
    end
  end
  # VALIDATION: SMELL END

  defp generate_key, do: :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)

  defp build_headers(idempotency_key \\ nil) do
    base = [
      {"Authorization", "Bearer #{System.get_env("PUSH_GATEWAY_KEY", "")}"},
      {"Content-Type", "application/json"}
    ]

    if idempotency_key,
      do: [{"Idempotency-Key", idempotency_key} | base],
      else: base
  end

  defp http_post(_url, _payload, _headers), do: {:error, :not_implemented}
end
```
