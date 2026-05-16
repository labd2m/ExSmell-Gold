# Annotated Example — Code Smell Validation

## Metadata

- **Smell name:** Complex branching
- **Expected smell location:** `process_charge_response/2` function
- **Affected function(s):** `process_charge_response/2`
- **Short explanation:** A single private function is responsible for pattern-matching every possible variant of a payment gateway's charge response — approved, declined, flagged, errored, and timed-out — across multiple nested `case` expressions. This concentration of all response-handling logic raises cyclomatic complexity to an unmanageable level, and a bug in any one branch (e.g., an unexpected nil field) can raise an exception that makes all other response types unreachable.

---

```elixir
defmodule Billing.PaymentGateway do
  @moduledoc """
  Wrapper around the third-party payment processor REST API.
  Supports charge creation, refunds, and dispute management.
  """

  require Logger

  @gateway_url "https://gateway.payments-provider.com/v3"
  @default_currency "USD"

  def charge(amount_cents, card_token, opts \\ []) do
    currency = Keyword.get(opts, :currency, @default_currency)
    idempotency_key = Keyword.get(opts, :idempotency_key, generate_key())
    metadata = Keyword.get(opts, :metadata, %{})

    payload = %{
      amount: amount_cents,
      currency: currency,
      source: card_token,
      capture: true,
      metadata: metadata
    }

    headers = [
      {"Authorization", "Bearer #{api_key()}"},
      {"Idempotency-Key", idempotency_key},
      {"Content-Type", "application/json"}
    ]

    case http_post("#{@gateway_url}/charges", payload, headers) do
      {:ok, raw_response} ->
        process_charge_response(raw_response, idempotency_key)

      {:error, :timeout} ->
        Logger.error("Gateway timeout for idempotency_key=#{idempotency_key}")
        {:error, :gateway_timeout}

      {:error, reason} ->
        Logger.error("HTTP error: #{inspect(reason)}")
        {:error, :transport_error}
    end
  end

  def refund(charge_id, amount_cents \\ nil) do
    payload = if amount_cents, do: %{amount: amount_cents}, else: %{}

    case http_post("#{@gateway_url}/charges/#{charge_id}/refund", payload, auth_headers()) do
      {:ok, %{status: 200, body: %{"refund_id" => rid}}} ->
        {:ok, %{refund_id: rid, charge_id: charge_id}}

      {:ok, %{status: 404}} ->
        {:error, :charge_not_found}

      {:ok, %{status: status}} ->
        {:error, {:unexpected_status, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # VALIDATION: SMELL START - Complex branching
  # VALIDATION: This is a smell because `process_charge_response/2` single-handedly
  # handles every possible HTTP status and nested body variant from one gateway
  # endpoint. The outer `case` on HTTP status fans out into further inner `case`
  # expressions on the body, producing a deeply nested, high-complexity function.
  # Each branch is tightly coupled to a specific body schema; if any branch raises
  # (e.g., missing key in a pattern), the whole function crashes, affecting all
  # callers regardless of which response type they would have matched.
  defp process_charge_response(response, idempotency_key) do
    case response do
      %{status: 200, body: body} ->
        case body do
          %{"status" => "succeeded", "charge_id" => cid, "amount" => amt, "receipt_url" => url} ->
            {:ok, %{charge_id: cid, amount: amt, receipt_url: url, status: :succeeded}}

          %{"status" => "succeeded", "charge_id" => cid, "amount" => amt} ->
            {:ok, %{charge_id: cid, amount: amt, receipt_url: nil, status: :succeeded}}

          %{"status" => "pending", "charge_id" => cid} ->
            Logger.info("Charge pending for key=#{idempotency_key} charge=#{cid}")
            {:ok, %{charge_id: cid, amount: nil, receipt_url: nil, status: :pending}}

          %{"status" => unknown} ->
            {:error, {:unknown_charge_status, unknown}}
        end

      %{status: 201, body: %{"charge_id" => cid, "status" => "authorized"}} ->
        {:ok, %{charge_id: cid, amount: nil, receipt_url: nil, status: :authorized}}

      %{status: 402, body: body} ->
        case body do
          %{"decline_code" => "insufficient_funds"} ->
            {:error, :insufficient_funds}

          %{"decline_code" => "card_expired"} ->
            {:error, :card_expired}

          %{"decline_code" => "do_not_honor"} ->
            {:error, :card_declined}

          %{"decline_code" => "stolen_card"} ->
            {:error, :stolen_card}

          %{"decline_code" => code} ->
            {:error, {:declined, code}}

          _ ->
            {:error, :payment_declined}
        end

      %{status: 400, body: %{"error" => %{"type" => "validation", "fields" => fields}}} ->
        {:error, {:validation_error, fields}}

      %{status: 400, body: %{"error" => %{"message" => msg}}} ->
        {:error, {:bad_request, msg}}

      %{status: 400} ->
        {:error, :bad_request}

      %{status: 401} ->
        Logger.error("Gateway auth failure for key=#{idempotency_key}")
        {:error, :unauthorized}

      %{status: 409, body: %{"existing_charge_id" => cid}} ->
        Logger.warning("Duplicate charge detected, original=#{cid}")
        {:error, {:duplicate_charge, cid}}

      %{status: 409} ->
        {:error, :conflict}

      %{status: 422, body: %{"error" => %{"code" => code, "message" => msg}}} ->
        {:error, {:unprocessable, code, msg}}

      %{status: 429, body: %{"retry_after" => ra}} ->
        {:error, {:rate_limited, ra}}

      %{status: 429} ->
        {:error, :rate_limited}

      %{status: 500, body: %{"request_id" => rid}} ->
        Logger.error("Gateway 500, request_id=#{rid}")
        {:error, {:gateway_error, rid}}

      %{status: 500} ->
        {:error, :gateway_error}

      %{status: 503} ->
        {:error, :gateway_unavailable}

      %{status: status, body: body} ->
        Logger.warning("Unhandled gateway status=#{status}, body=#{inspect(body)}")
        {:error, {:unhandled_response, status}}
    end
  end
  # VALIDATION: SMELL END

  defp auth_headers do
    [{"Authorization", "Bearer #{api_key()}"}, {"Content-Type", "application/json"}]
  end

  defp api_key, do: System.get_env("PAYMENT_GATEWAY_API_KEY", "")

  defp generate_key, do: :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)

  defp http_post(_url, _payload, _headers), do: {:error, :not_implemented}
end
```
