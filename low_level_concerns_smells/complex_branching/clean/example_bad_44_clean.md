```elixir
defmodule Notifications.EmailDeliveryClient do
  @moduledoc """
  HTTP client for the transactional email delivery provider.
  Handles single and batch email dispatch, template rendering,
  bounce management, and suppression list queries.
  """

  require Logger

  @base_url "https://email-api.provider.com/v4"
  @default_from "noreply@myapp.com"

  def send_email(to, subject, body_html, opts \\ []) do
    from = Keyword.get(opts, :from, @default_from)
    reply_to = Keyword.get(opts, :reply_to)
    attachments = Keyword.get(opts, :attachments, [])
    tags = Keyword.get(opts, :tags, [])
    idempotency_key = Keyword.get(opts, :idempotency_key, generate_key())

    payload = %{
      from: from,
      to: List.wrap(to),
      reply_to: reply_to,
      subject: subject,
      html_body: body_html,
      attachments: attachments,
      tags: tags
    }

    headers = build_headers(idempotency_key)

    case http_post("#{@base_url}/emails", payload, headers) do
      {:ok, raw} ->
        interpret_send_response(raw, %{to: to, key: idempotency_key})

      {:error, :timeout} ->
        {:error, :provider_timeout}

      {:error, reason} ->
        {:error, {:transport, reason}}
    end
  end

  def send_template(to, template_id, variables, opts \\ []) do
    from = Keyword.get(opts, :from, @default_from)
    idempotency_key = Keyword.get(opts, :idempotency_key, generate_key())

    payload = %{
      from: from,
      to: List.wrap(to),
      template_id: template_id,
      template_variables: variables
    }

    case http_post("#{@base_url}/emails/template", payload, build_headers(idempotency_key)) do
      {:ok, raw} ->
        interpret_send_response(raw, %{to: to, template: template_id})

      {:error, reason} ->
        {:error, {:transport, reason}}
    end
  end

  def suppression_status(email) do
    case http_get("#{@base_url}/suppressions/#{URI.encode(email)}", build_headers()) do
      {:ok, %{status: 200, body: %{"suppressed" => true, "reason" => reason}}} ->
        {:ok, %{suppressed: true, reason: reason}}

      {:ok, %{status: 200, body: %{"suppressed" => false}}} ->
        {:ok, %{suppressed: false}}

      {:ok, %{status: 404}} ->
        {:ok, %{suppressed: false}}

      {:ok, %{status: status}} ->
        {:error, {:unexpected_status, status}}

      {:error, reason} ->
        {:error, {:transport, reason}}
    end
  end

  defp interpret_send_response(response, context) do
    case response do
      %{status: 200, body: body} ->
        case body do
          %{
            "status" => "queued",
            "message_id" => mid,
            "queue_time_ms" => qt
          } ->
            {:ok, %{message_id: mid, status: :queued, queue_time_ms: qt, delivered_at: nil}}

          %{"status" => "queued", "message_id" => mid} ->
            {:ok, %{message_id: mid, status: :queued, queue_time_ms: nil, delivered_at: nil}}

          %{
            "status" => "delivered",
            "message_id" => mid,
            "delivered_at" => ts,
            "open_tracked" => tracked
          } ->
            {:ok,
             %{message_id: mid, status: :delivered, delivered_at: ts, open_tracked: tracked}}

          %{"status" => "scheduled", "message_id" => mid, "send_at" => ts} ->
            {:ok, %{message_id: mid, status: :scheduled, send_at: ts, delivered_at: nil}}

          %{"status" => unknown} ->
            {:error, {:unknown_email_status, unknown}}

          _ ->
            {:error, :malformed_send_body}
        end

      %{status: 202, body: %{"message_id" => mid}} ->
        Logger.info("Email accepted async message_id=#{mid} context=#{inspect(context)}")
        {:ok, %{message_id: mid, status: :accepted, delivered_at: nil}}

      %{status: 400, body: body} ->
        case body do
          %{"error" => "invalid_email", "address" => addr} ->
            {:error, {:invalid_email, addr}}

          %{"error" => "suppressed_recipient", "suppressed_at" => ts} ->
            {:error, {:suppressed_recipient, ts}}

          %{"error" => "invalid_attachment", "filename" => fname, "reason" => reason} ->
            {:error, {:invalid_attachment, fname, reason}}

          %{"error" => "attachment_too_large", "max_bytes" => max} ->
            {:error, {:attachment_too_large, max}}

          %{"error" => "template_not_found", "template_id" => tid} ->
            {:error, {:template_not_found, tid}}

          %{"error" => "template_variable_missing", "variable" => var} ->
            {:error, {:template_variable_missing, var}}

          %{"error" => "html_too_large", "max_bytes" => max} ->
            {:error, {:html_too_large, max}}

          %{"error" => msg} ->
            {:error, {:bad_request, msg}}

          _ ->
            {:error, :bad_request}
        end

      %{status: 401} ->
        Logger.error("Email provider unauthorized context=#{inspect(context)}")
        {:error, :unauthorized}

      %{status: 402, body: %{"error" => "quota_exceeded", "reset_at" => reset}} ->
        {:error, {:quota_exceeded, reset}}

      %{status: 402} ->
        {:error, :quota_exceeded}

      %{status: 403, body: %{"error" => "domain_not_verified", "domain" => domain}} ->
        {:error, {:domain_not_verified, domain}}

      %{status: 403, body: %{"error" => "ip_not_whitelisted", "ip" => ip}} ->
        {:error, {:ip_not_whitelisted, ip}}

      %{status: 403} ->
        {:error, :forbidden}

      %{status: 429, body: %{"retry_after" => sec, "burst_limit" => lim}} ->
        {:error, {:rate_limited, sec, lim}}

      %{status: 429} ->
        {:error, :rate_limited}

      %{status: 451, body: %{"blocked_regions" => regions}} ->
        {:error, {:legally_blocked, regions}}

      %{status: 451} ->
        {:error, :legally_blocked}

      %{status: 500, body: %{"request_id" => rid, "detail" => detail}} ->
        Logger.error("Email provider 500 request_id=#{rid} detail=#{detail}")
        {:error, {:server_error, rid}}

      %{status: 500} ->
        {:error, :server_error}

      %{status: 503, body: %{"maintenance_until" => ts}} ->
        {:error, {:maintenance, ts}}

      %{status: 503} ->
        {:error, :service_unavailable}

      %{status: status, body: body} ->
        Logger.warning("Unhandled email provider status=#{status} body=#{inspect(body)}")
        {:error, {:unhandled_response, status}}
    end
  end

  defp generate_key, do: :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)

  defp build_headers(idempotency_key \\ nil) do
    base = [
      {"Authorization", "Bearer #{System.get_env("EMAIL_API_KEY", "")}"},
      {"Content-Type", "application/json"}
    ]

    if idempotency_key,
      do: [{"Idempotency-Key", idempotency_key} | base],
      else: base
  end

  defp http_post(_url, _payload, _headers), do: {:error, :not_implemented}
  defp http_get(_url, _headers), do: {:error, :not_implemented}
end
```
