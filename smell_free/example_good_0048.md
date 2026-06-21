```elixir
defmodule Payments.GatewayClient do
  @moduledoc """
  HTTP client for the external payment gateway. Translates raw HTTP responses
  and transport errors into typed result tuples. All public functions return
  `{:ok, result}` or `{:error, reason}` — runtime gateway-level failures
  are communicated as values, never raised as exceptions.
  """

  require Logger

  @type charge_params :: %{
          amount_cents: pos_integer(),
          currency: String.t(),
          source_token: String.t(),
          idempotency_key: String.t()
        }

  @type charge_result :: %{
          charge_id: String.t(),
          status: :succeeded | :pending | :failed,
          amount_cents: pos_integer()
        }

  @type gateway_error ::
          :insufficient_funds | :card_declined | :invalid_token
          | :gateway_timeout | :gateway_error

  @doc """
  Submits a charge request. Accepts optional `base_url` and `api_key` overrides
  for multi-tenant and testing scenarios.
  """
  @spec charge(charge_params(), keyword()) ::
          {:ok, charge_result()} | {:error, gateway_error()}
  def charge(%{amount_cents: amount} = params, opts \\ [])
      when is_integer(amount) and amount > 0 do
    base_url = Keyword.get(opts, :base_url, default_base_url())
    api_key = Keyword.get(opts, :api_key, default_api_key())

    headers = build_headers(api_key, params.idempotency_key)
    body = Jason.encode!(build_body(params))

    "#{base_url}/v1/charges"
    |> HTTPoison.post(body, headers, recv_timeout: 10_000)
    |> parse_response()
  end

  defp build_headers(api_key, idempotency_key) do
    [
      {"Authorization", "Bearer #{api_key}"},
      {"Content-Type", "application/json"},
      {"Idempotency-Key", idempotency_key}
    ]
  end

  defp build_body(%{amount_cents: a, currency: c, source_token: s}) do
    %{amount: a, currency: c, source: s}
  end

  defp parse_response({:ok, %{status_code: 200, body: body}}) do
    case Jason.decode(body) do
      {:ok, %{"id" => id, "status" => status, "amount" => amount}} ->
        {:ok, %{charge_id: id, status: map_status(status), amount_cents: amount}}

      _ ->
        {:error, :gateway_error}
    end
  end

  defp parse_response({:ok, %{status_code: 402, body: body}}) do
    case Jason.decode(body) do
      {:ok, %{"error" => %{"code" => "insufficient_funds"}}} -> {:error, :insufficient_funds}
      {:ok, %{"error" => %{"code" => "invalid_token"}}} -> {:error, :invalid_token}
      _ -> {:error, :card_declined}
    end
  end

  defp parse_response({:ok, %{status_code: code}}) when code in 500..503 do
    {:error, :gateway_error}
  end

  defp parse_response({:error, %HTTPoison.Error{reason: :timeout}}) do
    {:error, :gateway_timeout}
  end

  defp parse_response({:error, _reason}) do
    {:error, :gateway_error}
  end

  defp map_status("succeeded"), do: :succeeded
  defp map_status("pending"), do: :pending
  defp map_status(_), do: :failed

  defp default_base_url, do: Application.fetch_env!(:my_app, :gateway_base_url)
  defp default_api_key, do: Application.fetch_env!(:my_app, :gateway_api_key)
end
```
