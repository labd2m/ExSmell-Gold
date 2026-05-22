```elixir
defmodule Webhooks.SignatureVerifier do
  @moduledoc """
  Verifies and generates HMAC-SHA256 signatures for inbound and outbound
  webhooks. Ensures that payloads originate from trusted senders and have
  not been tampered with in transit.

  This module is published as a library dependency consumed by the main
  application and by partner integrations.
  """

  require Logger

  @signature_header "X-Webhook-Signature-256"
  @signature_prefix "sha256="
  @timestamp_tolerance_seconds 300

  @webhook_signing_secret Application.fetch_env!(:webhooks, :signing_secret)

  @type verification_result ::
          :ok
          | {:error, :missing_signature | :invalid_signature | :replay_attack | :malformed}

  @doc """
  Verifies the HMAC-SHA256 signature of an inbound webhook payload.

  Checks both the cryptographic signature and the request timestamp to
  guard against replay attacks.

  ## Parameters
    - `raw_body` - The raw request body binary (must not be parsed first).
    - `signature_header` - The value of the `#{@signature_header}` HTTP header.
    - `timestamp` - Unix timestamp from the request (as integer or string).
  """
  @spec verify_signature(binary(), String.t() | nil, integer() | String.t()) ::
          verification_result()
  def verify_signature(_raw_body, nil, _timestamp) do
    Logger.warning("Webhook received with missing signature header")
    {:error, :missing_signature}
  end

  def verify_signature(raw_body, signature_header, timestamp)
      when is_binary(raw_body) and is_binary(signature_header) do
    with {:ok, ts} <- parse_timestamp(timestamp),
         :ok <- check_timestamp_freshness(ts),
         {:ok, claimed_sig} <- extract_signature(signature_header) do
      signing_payload = "#{ts}.#{raw_body}"
      expected = compute_hmac(signing_payload)

      if Plug.Crypto.secure_compare(expected, claimed_sig) do
        Logger.debug("Webhook signature verified")
        :ok
      else
        Logger.warning("Webhook signature mismatch")
        {:error, :invalid_signature}
      end
    end
  end

  @doc """
  Generates a signature for an outbound webhook payload so that receivers
  can verify its authenticity.

  ## Parameters
    - `payload` - The JSON-encoded string to sign.

  ## Returns
    - A `{signature, timestamp}` tuple ready to attach as HTTP headers.
  """
  @spec sign_payload(String.t()) :: {String.t(), integer()}
  def sign_payload(payload) when is_binary(payload) do
    ts = System.system_time(:second)
    signing_payload = "#{ts}.#{payload}"
    sig = @signature_prefix <> compute_hmac(signing_payload)
    Logger.debug("Webhook payload signed ts=#{ts}")
    {sig, ts}
  end

  @doc """
  Builds the header map needed for an outbound webhook request.
  Convenience wrapper around `sign_payload/1`.
  """
  @spec outbound_headers(String.t()) :: [{String.t(), String.t()}]
  def outbound_headers(payload) when is_binary(payload) do
    {sig, ts} = sign_payload(payload)

    [
      {@signature_header, sig},
      {"X-Webhook-Timestamp", to_string(ts)},
      {"Content-Type", "application/json"}
    ]
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp compute_hmac(data) do
    :crypto.mac(:hmac, :sha256, @webhook_signing_secret, data)
    |> Base.encode16(case: :lower)
  end

  defp extract_signature(@signature_prefix <> hex), do: {:ok, hex}
  defp extract_signature(_), do: {:error, :malformed}

  defp parse_timestamp(ts) when is_integer(ts), do: {:ok, ts}

  defp parse_timestamp(ts) when is_binary(ts) do
    case Integer.parse(ts) do
      {int, ""} -> {:ok, int}
      _ -> {:error, :malformed}
    end
  end

  defp check_timestamp_freshness(ts) do
    age = abs(System.system_time(:second) - ts)

    if age <= @timestamp_tolerance_seconds do
      :ok
    else
      Logger.warning("Webhook timestamp too old age_seconds=#{age}")
      {:error, :replay_attack}
    end
  end
end
```
