```elixir
defmodule Integrations.PaymentGateway do
  @moduledoc """
  Client adapter for the external payment gateway REST API.
  Handles transaction creation, capture, refund, and status queries.

  Expected successful charge response structure:
    {
      "data": {
        "id": "txn_abc123",
        "status": "authorized",
        "amount": 9990,
        "currency": "BRL",
        "payment_method": {
          "type": "credit_card",
          "last_four": "4242",
          "brand": "visa"
        },
        "created_at": "2024-03-15T14:22:00Z",
        "metadata": { "order_id": "ORD-00456" }
      }
    }
  """

  require Logger

  @base_url  Application.compile_env(:integrations, [:payment_gateway, :base_url], "https://api.paygw.example.com")
  @api_key   Application.compile_env(:integrations, [:payment_gateway, :api_key], "")

  def charge(amount_cents, currency, payment_token, metadata \\ %{}) do
    body = %{
      amount:        amount_cents,
      currency:      currency,
      payment_token: payment_token,
      metadata:      metadata
    }

    with {:ok, response} <- post("/charges", body),
         {:ok, decoded}  <- Jason.decode(response) do
      {:ok, extract_transaction(decoded)}
    end
  end

  def refund(transaction_id, amount_cents \\ nil) do
    body = if amount_cents, do: %{amount: amount_cents}, else: %{}

    with {:ok, response} <- post("/charges/#{transaction_id}/refund", body),
         {:ok, decoded}  <- Jason.decode(response) do
      {:ok, extract_transaction(decoded)}
    end
  end

  defp extract_transaction(response) do
    %{
      id:              get_in(response, ["data", "id"]),
      status:          get_in(response, ["data", "status"]),
      amount:          get_in(response, ["data", "amount"]),
      currency:        get_in(response, ["data", "currency"]),
      payment_type:    get_in(response, ["data", "payment_method", "type"]),
      card_last_four:  get_in(response, ["data", "payment_method", "last_four"]),
      card_brand:      get_in(response, ["data", "payment_method", "brand"]),
      created_at:      get_in(response, ["data", "created_at"]),
      order_id:        get_in(response, ["data", "metadata", "order_id"])
    }
  end

  def authorized?(%{status: "authorized"}), do: true
  def authorized?(_), do: false

  def captured?(%{status: "captured"}), do: true
  def captured?(_), do: false

  def refunded?(%{status: "refunded"}), do: true
  def refunded?(_), do: false

  def format_transaction(%{id: id, status: status, amount: amount, currency: currency}) do
    amount_str = if is_integer(amount), do: "#{div(amount, 100)}.#{rem(amount, 100)}", else: "?"
    "#{id} [#{status}] #{currency} #{amount_str}"
  end

  def format_transaction(_), do: "Unknown transaction"

  defp post(path, body) do
    url     = @base_url <> path
    headers = [{"Authorization", "Bearer #{@api_key}"}, {"Content-Type", "application/json"}]
    payload = Jason.encode!(body)

    case :httpc.request(:post, {String.to_charlist(url), headers, ~c"application/json", payload}, [], []) do
      {:ok, {{_, 200, _}, _headers, response_body}} ->
        {:ok, List.to_string(response_body)}

      {:ok, {{_, status, _}, _headers, response_body}} ->
        Logger.error("Gateway error #{status}: #{response_body}")
        {:error, {:gateway_error, status}}

      {:error, reason} ->
        Logger.error("HTTP error: #{inspect(reason)}")
        {:error, {:http_error, reason}}
    end
  end
end
```
