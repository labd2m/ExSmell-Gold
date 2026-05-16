```elixir
defmodule MyApp.Payments.GatewayClient do
  @moduledoc """
  HTTP client wrapper for the external payment gateway.
  Handles charge, refund, and authorization requests.
  """

  require Logger

  alias MyApp.Payments.{TransactionLog, FraudGuard}

  @gateway_base_url "https://api.paymentgateway.io/v2"
  @timeout_ms 10_000
  @idempotency_header "Idempotency-Key"

  @spec process_charge(map(), keyword()) :: {:ok, map()} | {:error, atom() | map()}
  def process_charge(charge_params, opts \\ []) do
    idempotency_key = Keyword.get(opts, :idempotency_key, generate_key())
    headers = build_headers(idempotency_key)
    body = Jason.encode!(charge_params)

    Logger.info("Initiating charge: amount=#{charge_params.amount} customer=#{charge_params.customer_id}")

    case HTTPoison.post("#{@gateway_base_url}/charges", body, headers, recv_timeout: @timeout_ms) do
      {:ok, %HTTPoison.Response{status_code: 200, body: resp_body}} ->
        parsed = Jason.decode!(resp_body)
        TransactionLog.record(:success, parsed)
        {:ok, parsed}

      {:ok, %HTTPoison.Response{status_code: 201, body: resp_body}} ->
        parsed = Jason.decode!(resp_body)
        TransactionLog.record(:success, parsed)
        {:ok, parsed}

      {:ok, %HTTPoison.Response{status_code: 402, body: resp_body}} ->
        parsed = Jason.decode!(resp_body)
        case parsed["decline_code"] do
          "insufficient_funds" ->
            Logger.warning("Charge declined: insufficient funds customer=#{charge_params.customer_id}")
            TransactionLog.record(:declined, parsed)
            {:error, :insufficient_funds}

          "card_expired" ->
            Logger.warning("Charge declined: card expired customer=#{charge_params.customer_id}")
            TransactionLog.record(:declined, parsed)
            {:error, :card_expired}

          "do_not_honor" ->
            Logger.warning("Charge declined: do_not_honor customer=#{charge_params.customer_id}")
            TransactionLog.record(:declined, parsed)
            {:error, :do_not_honor}

          "lost_card" ->
            Logger.warning("Charge declined: lost card customer=#{charge_params.customer_id}")
            FraudGuard.flag_customer(charge_params.customer_id, :lost_card)
            TransactionLog.record(:fraud_suspected, parsed)
            {:error, :lost_card}

          "stolen_card" ->
            Logger.warning("Charge declined: stolen card customer=#{charge_params.customer_id}")
            FraudGuard.flag_customer(charge_params.customer_id, :stolen_card)
            TransactionLog.record(:fraud_suspected, parsed)
            {:error, :stolen_card}

          _other ->
            Logger.warning("Charge declined: unclassified reason customer=#{charge_params.customer_id}")
            TransactionLog.record(:declined, parsed)
            {:error, :card_declined}
        end

      {:ok, %HTTPoison.Response{status_code: 400, body: resp_body}} ->
        parsed = Jason.decode!(resp_body)
        Logger.error("Charge bad request: #{inspect(parsed)}")
        {:error, {:bad_request, parsed}}

      {:ok, %HTTPoison.Response{status_code: 401}} ->
        Logger.error("Gateway authentication failed")
        {:error, :authentication_failed}

      {:ok, %HTTPoison.Response{status_code: 409, body: resp_body}} ->
        parsed = Jason.decode!(resp_body)
        Logger.info("Duplicate charge detected: idempotency_key=#{idempotency_key}")
        {:ok, parsed}

      {:ok, %HTTPoison.Response{status_code: 422, body: resp_body}} ->
        parsed = Jason.decode!(resp_body)
        Logger.warning("Charge unprocessable: #{inspect(parsed["errors"])}")
        {:error, {:validation_failed, parsed["errors"]}}

      {:ok, %HTTPoison.Response{status_code: 429}} ->
        Logger.warning("Gateway rate limit exceeded")
        {:error, :rate_limited}

      {:ok, %HTTPoison.Response{status_code: status}} when status >= 500 ->
        Logger.error("Gateway server error: status=#{status}")
        {:error, :gateway_unavailable}

      {:error, %HTTPoison.Error{reason: :timeout}} ->
        Logger.error("Gateway request timed out for customer=#{charge_params.customer_id}")
        {:error, :gateway_timeout}

      {:error, %HTTPoison.Error{reason: reason}} ->
        Logger.error("Gateway network error: #{inspect(reason)}")
        {:error, :network_error}
    end
  end

  @spec refund(String.t(), number()) :: {:ok, map()} | {:error, atom()}
  def refund(transaction_id, amount) do
    headers = build_headers(generate_key())
    body = Jason.encode!(%{amount: amount})

    case HTTPoison.post("#{@gateway_base_url}/refunds/#{transaction_id}", body, headers,
           recv_timeout: @timeout_ms
         ) do
      {:ok, %HTTPoison.Response{status_code: status, body: resp_body}} when status in [200, 201] ->
        {:ok, Jason.decode!(resp_body)}

      {:ok, %HTTPoison.Response{status_code: status, body: body}} ->
        Logger.error("Refund failed: status=#{status} body=#{body}")
        {:error, :refund_failed}

      {:error, %HTTPoison.Error{reason: reason}} ->
        Logger.error("Refund network error: #{inspect(reason)}")
        {:error, :network_error}
    end
  end

  # Private helpers

  defp build_headers(idempotency_key) do
    api_key = Application.fetch_env!(:my_app, :gateway_api_key)

    [
      {"Authorization", "Bearer #{api_key}"},
      {"Content-Type", "application/json"},
      {"Accept", "application/json"},
      {@idempotency_header, idempotency_key}
    ]
  end

  defp generate_key do
    :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
  end
end
```
