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

  defp auth_headers do
    [{"Authorization", "Bearer #{api_key()}"}, {"Content-Type", "application/json"}]
  end

  defp api_key, do: System.get_env("PAYMENT_GATEWAY_API_KEY", "")

  defp generate_key, do: :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)

  defp http_post(_url, _payload, _headers), do: {:error, :not_implemented}
end
```
