```elixir
defmodule Notifications.SmsProviderClient do
  @moduledoc """
  HTTP client for the third-party SMS delivery provider.
  Handles single message dispatch, bulk sends, delivery status polling,
  and opt-out management.
  """

  require Logger

  @base_url "https://sms-gateway.provider.io/v3"
  @default_sender_id "MYAPP"

  def send_message(to_number, body, opts \\ []) do
    sender_id = Keyword.get(opts, :sender_id, @default_sender_id)
    scheduled_at = Keyword.get(opts, :scheduled_at)
    idempotency_key = Keyword.get(opts, :idempotency_key, generate_key())
    priority = Keyword.get(opts, :priority, "normal")

    payload = %{
      to: normalize_number(to_number),
      from: sender_id,
      body: body,
      priority: priority,
      scheduled_at: scheduled_at,
      idempotency_key: idempotency_key
    }

    case http_post("#{@base_url}/messages", payload, build_headers(idempotency_key)) do
      {:ok, raw} ->
        handle_send_response(raw, %{to: to_number, key: idempotency_key})

      {:error, :timeout} ->
        {:error, :provider_timeout}

      {:error, reason} ->
        {:error, {:transport, reason}}
    end
  end

  def delivery_status(message_id) do
    case http_get("#{@base_url}/messages/#{message_id}", build_headers()) do
      {:ok, %{status: 200, body: %{"status" => status, "delivered_at" => ts}}} ->
        {:ok, %{message_id: message_id, status: String.to_atom(status), delivered_at: ts}}

      {:ok, %{status: 200, body: %{"status" => status}}} ->
        {:ok, %{message_id: message_id, status: String.to_atom(status), delivered_at: nil}}

      {:ok, %{status: 404}} ->
        {:error, :message_not_found}

      {:ok, %{status: status}} ->
        {:error, {:unexpected_status, status}}

      {:error, reason} ->
        {:error, {:transport, reason}}
    end
  end

  def cancel_scheduled(message_id) do
    case http_delete("#{@base_url}/messages/#{message_id}", build_headers()) do
      {:ok, %{status: 200}} -> :ok
      {:ok, %{status: 404}} -> {:error, :message_not_found}
      {:ok, %{status: 409}} -> {:error, :already_sent}
      {:ok, %{status: status}} -> {:error, {:unexpected_status, status}}
      {:error, reason} -> {:error, {:transport, reason}}
    end
  end

  defp handle_send_response(response, context) do
    case response do
      %{status: 200, body: body} ->
        case body do
          %{
            "status" => "queued",
            "message_id" => mid,
            "segments" => segs,
            "estimated_delivery" => eta
          } ->
            {:ok, %{message_id: mid, status: :queued, segments: segs, estimated_delivery: eta}}

          %{"status" => "queued", "message_id" => mid, "segments" => segs} ->
            {:ok, %{message_id: mid, status: :queued, segments: segs, estimated_delivery: nil}}

          %{"status" => "delivered", "message_id" => mid, "delivered_at" => ts} ->
            {:ok, %{message_id: mid, status: :delivered, segments: 1, delivered_at: ts}}

          %{"status" => "scheduled", "message_id" => mid, "scheduled_at" => ts} ->
            {:ok, %{message_id: mid, status: :scheduled, scheduled_at: ts, segments: nil}}

          %{"status" => unknown} ->
            {:error, {:unknown_sms_status, unknown}}

          _ ->
            {:error, :malformed_send_response}
        end

      %{status: 202, body: %{"message_id" => mid}} ->
        Logger.info("SMS accepted async message_id=#{mid} context=#{inspect(context)}")
        {:ok, %{message_id: mid, status: :accepted, segments: nil}}

      %{status: 400, body: body} ->
        case body do
          %{"error" => "invalid_number", "number" => num} ->
            {:error, {:invalid_number, num}}

          %{"error" => "number_blacklisted", "number" => num} ->
            {:error, {:number_blacklisted, num}}

          %{"error" => "opt_out", "opted_out_at" => ts} ->
            {:error, {:opted_out, ts}}

          %{"error" => "opt_out"} ->
            {:error, :opted_out}

          %{"error" => "content_violation", "rule" => rule} ->
            {:error, {:content_violation, rule}}

          %{"error" => "message_too_long", "max_length" => max} ->
            {:error, {:message_too_long, max}}

          %{"error" => "invalid_sender_id", "detail" => detail} ->
            {:error, {:invalid_sender_id, detail}}

          %{"error" => msg} ->
            {:error, {:bad_request, msg}}

          _ ->
            {:error, :bad_request}
        end

      %{status: 401} ->
        Logger.error("SMS provider unauthorized context=#{inspect(context)}")
        {:error, :unauthorized}

      %{status: 402, body: %{"balance" => bal, "required" => req}} ->
        Logger.warning("Insufficient SMS credits balance=#{bal} required=#{req}")
        {:error, {:insufficient_credits, %{balance: bal, required: req}}}

      %{status: 402} ->
        {:error, :insufficient_credits}

      %{status: 429, body: %{"retry_after" => sec, "limit" => lim}} ->
        {:error, {:rate_limited, sec, lim}}

      %{status: 429} ->
        {:error, :rate_limited}

      %{status: 451, body: %{"blocked_regions" => regions}} ->
        {:error, {:legally_blocked, regions}}

      %{status: 451} ->
        {:error, :legally_blocked}

      %{status: 500, body: %{"request_id" => rid}} ->
        Logger.error("SMS provider 500 request_id=#{rid} context=#{inspect(context)}")
        {:error, {:server_error, rid}}

      %{status: 500} ->
        {:error, :server_error}

      %{status: 503} ->
        {:error, :service_unavailable}

      %{status: status, body: body} ->
        Logger.warning("Unhandled SMS response status=#{status} body=#{inspect(body)}")
        {:error, {:unhandled_response, status}}
    end
  end
  
  defp normalize_number("+" <> _ = num), do: num
  defp normalize_number(num), do: "+1#{num}"

  defp generate_key, do: :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)

  defp build_headers(idempotency_key \\ nil) do
    base = [
      {"Authorization", "Bearer #{System.get_env("SMS_PROVIDER_KEY", "")}"},
      {"Content-Type", "application/json"}
    ]

    if idempotency_key,
      do: [{"Idempotency-Key", idempotency_key} | base],
      else: base
  end

  defp http_post(_url, _payload, _headers), do: {:error, :not_implemented}
  defp http_get(_url, _headers), do: {:error, :not_implemented}
  defp http_delete(_url, _headers), do: {:error, :not_implemented}
end
```
