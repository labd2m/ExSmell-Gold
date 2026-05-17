# Annotated Example — Speculative Assumptions

## Metadata

- **Smell name:** Speculative Assumptions
- **Expected smell location:** `Payments.WebhookVerifier.extract_signature/1`, around the header split and list access
- **Affected function(s):** `extract_signature/1`
- **Short explanation:** The function splits a raw `Stripe-Signature` header by "," and then "=" to extract the signature value, using `Enum.at/2` to pick positional elements. If the header format changes (e.g., contains extra key=value pairs before the signature, or the signature value itself contains "="), `Enum.at/2` silently returns the wrong fragment. The function always returns *a* binary, so signature verification may silently pass with an incorrect value.

---

```elixir
defmodule Payments.WebhookVerifier do
  @moduledoc """
  Verifies the authenticity of incoming Stripe webhook events by validating
  the HMAC-SHA256 signature present in the Stripe-Signature header.

  Expected Stripe-Signature header format:
    t=<unix_timestamp>,v1=<hex_signature>,v0=<legacy_hex_signature>
  """

  require Logger

  @signature_version "v1"
  @tolerance_seconds 300

  def verify(raw_body, signature_header, secret) do
    with {:ok, timestamp, signature} <- extract_signature(signature_header),
         :ok                         <- check_tolerance(timestamp),
         :ok                         <- verify_hmac(raw_body, timestamp, signature, secret) do
      {:ok, :verified}
    end
  end

  # VALIDATION: SMELL START - Speculative Assumptions
  # VALIDATION: This is a smell because the function splits the header string by ","
  # VALIDATION: to get pairs, then splits each pair by "=" and uses Enum.at/2 to
  # VALIDATION: read the key and value positionally. If any value contains "=" (which
  # VALIDATION: Base64/hex strings can), or if the pairs appear in a different order,
  # VALIDATION: Enum.at(kv, 1) silently returns only the fragment before the second "=".
  # VALIDATION: The function always produces {:ok, timestamp, signature} with whatever
  # VALIDATION: values were extracted — no crash, no error — so HMAC verification
  # VALIDATION: may be attempted with a truncated or misread signature, silently
  # VALIDATION: producing a false "verified" or a confusing mismatch error downstream.
  defp extract_signature(header) do
    pairs = String.split(header, ",")

    timestamp =
      Enum.find_value(pairs, fn pair ->
        kv = String.split(pair, "=")
        Enum.at(kv, 0) == "t" && Enum.at(kv, 1)
      end)

    signature =
      Enum.find_value(pairs, fn pair ->
        kv = String.split(pair, "=")
        Enum.at(kv, 0) == @signature_version && Enum.at(kv, 1)
      end)

    {:ok, timestamp, signature}
  end
  # VALIDATION: SMELL END

  defp check_tolerance(timestamp) when is_binary(timestamp) do
    case Integer.parse(timestamp) do
      {ts, _} ->
        now = System.system_time(:second)

        if abs(now - ts) <= @tolerance_seconds do
          :ok
        else
          {:error, :timestamp_out_of_tolerance}
        end

      :error ->
        {:error, :invalid_timestamp}
    end
  end

  defp check_tolerance(nil), do: {:error, :missing_timestamp}

  defp verify_hmac(raw_body, timestamp, signature, secret) do
    payload   = "#{timestamp}.#{raw_body}"
    expected  = :crypto.mac(:hmac, :sha256, secret, payload) |> Base.encode16(case: :lower)

    if Plug.Crypto.secure_compare(expected, signature || "") do
      :ok
    else
      {:error, :signature_mismatch}
    end
  end

  def parse_event(verified_body) when is_binary(verified_body) do
    case Jason.decode(verified_body) do
      {:ok, %{"type" => type, "data" => data, "id" => id}} ->
        {:ok, %{id: id, type: type, data: data}}

      {:ok, _} ->
        {:error, :unexpected_event_shape}

      {:error, reason} ->
        {:error, {:json_decode_failed, reason}}
    end
  end

  def dispatch(%{type: "payment_intent.succeeded"} = event) do
    Logger.info("Payment succeeded: #{event.id}")
    {:ok, :payment_recorded}
  end

  def dispatch(%{type: "charge.refunded"} = event) do
    Logger.info("Refund processed: #{event.id}")
    {:ok, :refund_recorded}
  end

  def dispatch(%{type: type}) do
    Logger.debug("Unhandled webhook event type: #{type}")
    {:ok, :ignored}
  end
end
```
