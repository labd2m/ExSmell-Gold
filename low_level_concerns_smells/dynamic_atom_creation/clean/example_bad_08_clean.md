```elixir
defmodule MyApp.Payments.PaymentGatewayAdapter do
  @moduledoc """
  Adapter for the external payment gateway HTTP API.
  Handles charge creation, refunds, and payment status polling.
  All monetary values are in the smallest currency unit (e.g., cents).
  """

  require Logger

  alias MyApp.Payments.{Charge, GatewayConfig}

  @gateway_base_url "https://api.paymentgateway.example.com/v2"
  @request_timeout_ms 10_000
  @idempotency_ttl_seconds 86_400

  @doc """
  Creates a charge via the payment gateway.
  """
  @spec create_charge(map()) :: {:ok, Charge.t()} | {:error, term()}
  def create_charge(%{amount_cents: amount, currency: currency, source: source} = params) do
    idempotency_key = build_idempotency_key(params)

    body = %{
      amount: amount,
      currency: String.downcase(currency),
      source: source,
      description: Map.get(params, :description, ""),
      metadata: Map.get(params, :metadata, %{})
    }

    Logger.info("Creating charge", amount: amount, currency: currency)

    case post("/charges", body, idempotency_key: idempotency_key) do
      {:ok, %{status: 201, body: response_body}} ->
        parse_response(response_body)

      {:ok, %{status: status, body: body}} ->
        Logger.warning("Gateway returned non-201 status", http_status: status)
        {:error, {:gateway_error, status, body}}

      {:error, reason} ->
        Logger.error("HTTP request to gateway failed", reason: inspect(reason))
        {:error, {:http_error, reason}}
    end
  end

  @doc """
  Issues a full or partial refund for an existing charge.
  """
  @spec refund(String.t(), non_neg_integer() | :full) :: {:ok, map()} | {:error, term()}
  def refund(charge_id, amount_or_full) do
    body =
      case amount_or_full do
        :full -> %{charge_id: charge_id}
        amount -> %{charge_id: charge_id, amount: amount}
      end

    case post("/refunds", body) do
      {:ok, %{status: 201, body: response_body}} -> parse_response(response_body)
      {:ok, %{status: status, body: body}} -> {:error, {:gateway_error, status, body}}
      {:error, reason} -> {:error, {:http_error, reason}}
    end
  end

  defp parse_response(%{"id" => id, "status" => status, "amount" => amount} = body) do
    charge = %Charge{
      gateway_id: id,
      status: String.to_atom(status),
      amount_cents: amount,
      currency: body["currency"],
      created_at: parse_unix_timestamp(body["created"]),
      metadata: body["metadata"] || %{}
    }

    {:ok, charge}
  end

  defp parse_response(body) do
    Logger.warning("Unexpected gateway response format", body: inspect(body))
    {:error, :unexpected_response_format}
  end

  defp post(path, body, opts \\ []) do
    url = @gateway_base_url <> path
    headers = build_headers(opts)
    encoded = Jason.encode!(body)

    case HTTPoison.post(url, encoded, headers, recv_timeout: @request_timeout_ms) do
      {:ok, %{status_code: status, body: raw_body}} ->
        {:ok, %{status: status, body: Jason.decode!(raw_body)}}

      {:error, %HTTPoison.Error{reason: reason}} ->
        {:error, reason}
    end
  end

  defp build_headers(opts) do
    base = [
      {"Content-Type", "application/json"},
      {"Authorization", "Bearer #{GatewayConfig.api_key()}"},
      {"User-Agent", "MyApp/1.0"}
    ]

    case Keyword.get(opts, :idempotency_key) do
      nil -> base
      key -> [{"Idempotency-Key", key} | base]
    end
  end

  defp build_idempotency_key(params) do
    :crypto.hash(:sha256, :erlang.term_to_binary(params)) |> Base.encode16(case: :lower)
  end

  defp parse_unix_timestamp(nil), do: DateTime.utc_now()
  defp parse_unix_timestamp(ts) when is_integer(ts), do: DateTime.from_unix!(ts)
end
```
