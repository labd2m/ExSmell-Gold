## Metadata

- **Smell name:** Speculative Generality
- **Expected smell location:** Function `list_supported_currencies/0` in `Payments.GatewayClient`
- **Affected function(s):** `list_supported_currencies/0`
- **Explanation:** `list_supported_currencies/0` was written speculatively, anticipating that the application would expose the list of accepted currencies to callers — for example, to populate a UI dropdown or to run upstream validation before a charge is attempted. In practice, currency validation is enforced by a hardcoded guard in the checkout controller, and this function is never called from any module in the codebase. It is dead code produced by an assumption about future requirements that was never realised.

---

```elixir
defmodule Payments.GatewayClient do
  @moduledoc """
  HTTP client interface for the external payment gateway.
  Handles charge creation, partial and full refunds, and payment method management.
  """

  alias Payments.{Charge, Refund, PaymentMethod, GatewayConfig}

  @gateway_base_url     "https://api.payments.example.com/v2"
  @default_timeout_ms   10_000
  @idempotency_prefix   "pk"

  def charge(%{amount: amount, currency: currency, customer_id: customer_id} = params) do
    idempotency_key = build_idempotency_key(customer_id, amount)

    payload = %{
      amount:         round(amount * 100),
      currency:       String.downcase(currency),
      customer:       customer_id,
      payment_method: params[:payment_method_id],
      description:    params[:description],
      metadata:       params[:metadata] || %{}
    }

    case post("/charges", payload, [{"Idempotency-Key", idempotency_key}]) do
      {:ok, %{"id" => id, "status" => status}} ->
        {:ok,
         %Charge{
           id:       id,
           status:   String.to_atom(status),
           amount:   amount,
           currency: currency
         }}

      {:ok, %{"error" => error}} ->
        {:error, error["message"]}

      {:error, _} = err ->
        err
    end
  end

  def refund(%Charge{id: charge_id}, amount_cents \\ nil) do
    payload =
      if amount_cents,
        do:   %{charge: charge_id, amount: amount_cents},
        else: %{charge: charge_id}

    case post("/refunds", payload, []) do
      {:ok, %{"id" => id, "status" => status}} ->
        {:ok, %Refund{id: id, charge_id: charge_id, status: String.to_atom(status)}}

      {:ok, %{"error" => error}} ->
        {:error, error["message"]}

      {:error, _} = err ->
        err
    end
  end

  def fetch_charge(charge_id) do
    case get("/charges/#{charge_id}") do
      {:ok, %{"id" => _} = raw}  -> {:ok, deserialise_charge(raw)}
      {:ok, %{"error" => error}} -> {:error, error["message"]}
      {:error, _} = err          -> err
    end
  end

  def attach_payment_method(customer_id, payment_method_token) do
    payload = %{customer: customer_id, payment_method: payment_method_token}

    case post("/customers/#{customer_id}/payment_methods", payload, []) do
      {:ok, %{"id" => id}} ->
        {:ok, %PaymentMethod{id: id, customer_id: customer_id}}

      {:ok, %{"error" => error}} ->
        {:error, error["message"]}

      {:error, _} = err ->
        err
    end
  end

  # VALIDATION: SMELL START - Speculative Generality
  # VALIDATION: This is a smell because `list_supported_currencies/0` was written
  # speculatively, anticipating a future need to expose the accepted currency list
  # to other parts of the application (e.g., a UI dropdown or an upstream
  # validation layer). In practice, currency validation is handled by a hardcoded
  # guard in the checkout controller, and this function is never called from any
  # module in the codebase. It is dead code added on the assumption of a future
  # requirement that never materialised.
  def list_supported_currencies do
    ["USD", "EUR", "GBP", "CAD", "AUD", "JPY", "CHF", "SGD", "HKD", "NZD"]
  end
  # VALIDATION: SMELL END

  defp post(path, payload, extra_headers) do
    url     = @gateway_base_url <> path
    headers = base_headers() ++ extra_headers
    body    = Jason.encode!(payload)

    case HTTPoison.post(url, body, headers, recv_timeout: @default_timeout_ms) do
      {:ok, %{status_code: code, body: raw}} when code in 200..299 ->
        {:ok, Jason.decode!(raw)}

      {:ok, %{status_code: code, body: raw}} ->
        {:error, {:gateway_error, code, Jason.decode!(raw)}}

      {:error, %{reason: reason}} ->
        {:error, {:network_error, reason}}
    end
  end

  defp get(path) do
    url = @gateway_base_url <> path

    case HTTPoison.get(url, base_headers(), recv_timeout: @default_timeout_ms) do
      {:ok, %{status_code: code, body: raw}} when code in 200..299 ->
        {:ok, Jason.decode!(raw)}

      {:ok, %{status_code: code, body: raw}} ->
        {:error, {:gateway_error, code, Jason.decode!(raw)}}

      {:error, %{reason: reason}} ->
        {:error, {:network_error, reason}}
    end
  end

  defp base_headers do
    config = GatewayConfig.current()

    [
      {"Content-Type",  "application/json"},
      {"Authorization", "Bearer #{config.api_key}"},
      {"X-Api-Version", "2024-11-01"}
    ]
  end

  defp build_idempotency_key(customer_id, amount) do
    suffix = System.unique_integer([:positive])
    "#{@idempotency_prefix}_#{customer_id}_#{round(amount * 100)}_#{suffix}"
  end

  defp deserialise_charge(%{"id" => id, "amount" => cents, "currency" => cur, "status" => s}) do
    %Charge{
      id:       id,
      amount:   cents / 100,
      currency: String.upcase(cur),
      status:   String.to_atom(s)
    }
  end
end
```
