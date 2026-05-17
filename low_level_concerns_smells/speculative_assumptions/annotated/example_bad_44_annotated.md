# Annotated Example — Speculative Assumptions

## Metadata

- **Smell name:** Speculative Assumptions
- **Expected smell location:** `Integrations.PaymentGateway.extract_transaction/1`, around the deeply nested `get_in/2` access
- **Affected function(s):** `extract_transaction/1`
- **Short explanation:** The function uses `get_in/2` with a hardcoded key path to navigate a deeply nested JSON-decoded map. `get_in/2` returns `nil` for any missing intermediate or leaf key without raising. If the payment gateway changes its response schema (e.g., wrapping `transaction` under `data.attributes` instead of `data`), every extracted field silently becomes `nil`, and the function returns a transaction struct filled with `nil` values that is indistinguishable from a valid one.

---

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

  # VALIDATION: SMELL START - Speculative Assumptions
  # VALIDATION: This is a smell because the function uses get_in/2 with hardcoded
  # VALIDATION: key paths like ["data", "id"], ["data", "payment_method", "last_four"],
  # VALIDATION: etc. get_in/2 returns nil for any key that is absent or for any
  # VALIDATION: intermediate nil (it does not raise). If the gateway API response
  # VALIDATION: changes its shape — for example wrapping data under "data" -> "attributes",
  # VALIDATION: or renaming "status" to "state" — every field in the returned transaction
  # VALIDATION: map becomes nil. The function always returns {:ok, transaction_map}
  # VALIDATION: even when every field is nil, so the caller sees a successful extraction
  # VALIDATION: of a transaction that has no id, no amount, and no status — silently
  # VALIDATION: corrupting charge records without any crash or error signal.
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
  # VALIDATION: SMELL END

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
