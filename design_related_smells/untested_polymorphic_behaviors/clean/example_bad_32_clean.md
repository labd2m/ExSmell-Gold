```elixir
defmodule Webhooks.PayloadSerializer do
  @moduledoc """
  Serializes outbound webhook payloads and constructs the HTTP request
  headers for webhook delivery. Supports HMAC-SHA256 request signing,
  idempotency keys, and custom header injection.

  Used by the webhook dispatcher and the delivery retry worker.
  """

  @signature_header "X-Webhook-Signature"
  @timestamp_header "X-Webhook-Timestamp"
  @delivery_id_header "X-Delivery-Id"
  @content_type_header "Content-Type"
  @default_content_type "application/json"
  @hmac_algorithm :sha256

  @doc """
  Builds the full set of HTTP headers for a webhook delivery attempt.

  ## Parameters
    - `payload_body`: The serialized JSON body binary.
    - `secret`: The shared HMAC secret for request signing.
    - `extra_headers`: Additional headers to include (keyword list or string map).
  """
  def build_headers(payload_body, secret, extra_headers \\ [])
      when is_binary(payload_body) and is_binary(secret) do
    timestamp = System.system_time(:second) |> Integer.to_string()
    delivery_id = generate_delivery_id()

    signature =
      compute_signature(payload_body, secret, timestamp)

    base_headers = %{
      @content_type_header => @default_content_type,
      @timestamp_header => timestamp,
      @delivery_id_header => delivery_id,
      @signature_header => "sha256=#{signature}"
    }

    normalized_extra = collect_headers(extra_headers)
    Map.merge(base_headers, normalized_extra)
  end

  @doc """
  Normalizes a header collection into a plain string-keyed map.
  Accepts keyword lists or string-keyed maps from caller-provided extra headers.
  """
  def collect_headers(headers) do
    Enum.into(headers, %{}, fn
      {k, v} when is_atom(k) -> {Atom.to_string(k), v}
      {k, v} when is_binary(k) -> {k, v}
    end)
  end

  @doc """
  Serializes an event map to a JSON binary for use as the webhook body.
  Returns `{:ok, json_body}` or `{:error, :serialization_failed}`.
  """
  def serialize_event(event) when is_map(event) do
    case Jason.encode(event) do
      {:ok, _} = result -> result
      {:error, _} -> {:error, :serialization_failed}
    end
  end

  @doc """
  Verifies the HMAC signature on an incoming webhook request.
  Returns `:ok` or `{:error, :invalid_signature}`.
  """
  def verify_signature(payload_body, secret, timestamp, received_sig)
      when is_binary(payload_body) and is_binary(secret) and
             is_binary(timestamp) and is_binary(received_sig) do
    expected = "sha256=#{compute_signature(payload_body, secret, timestamp)}"

    if Plug.Crypto.secure_compare(expected, received_sig) do
      :ok
    else
      {:error, :invalid_signature}
    end
  end

  @doc """
  Returns whether a delivery timestamp is within the acceptable tolerance window.
  Rejects replayed requests older than 5 minutes.
  """
  def timestamp_valid?(timestamp_str, tolerance_seconds \\ 300)
      when is_binary(timestamp_str) and is_integer(tolerance_seconds) do
    with {ts, ""} <- Integer.parse(timestamp_str) do
      abs(System.system_time(:second) - ts) <= tolerance_seconds
    else
      _ -> false
    end
  end

  @doc """
  Redacts the signature header value for safe logging.
  """
  def redact_signature(headers) when is_map(headers) do
    Map.update(headers, @signature_header, "[missing]", fn _ -> "[REDACTED]" end)
  end

  # --- Private ---

  defp compute_signature(body, secret, timestamp) do
    payload = "#{timestamp}.#{body}"

    :crypto.mac(:hmac, @hmac_algorithm, secret, payload)
    |> Base.encode16(case: :lower)
  end

  defp generate_delivery_id do
    :crypto.strong_rand_bytes(12)
    |> Base.url_encode64(padding: false)
  end
end
```
