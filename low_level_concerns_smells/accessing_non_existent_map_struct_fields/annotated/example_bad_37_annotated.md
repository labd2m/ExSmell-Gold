# Code Smell: Accessing Non-Existent Map/Struct Fields

- **Smell name:** Accessing non-existent Map/Struct fields
- **Expected smell location:** `Payments.GatewayAdapter.charge/1`, where optional payment metadata fields are accessed dynamically
- **Affected function(s):** `charge/1`
- **Short explanation:** The function reads `:idempotency_key`, `:descriptor`, and `:capture_immediately` from the charge request map using bracket notation. Missing keys return `nil` silently, so a request without an idempotency key proceeds without deduplication protection, and missing descriptor/capture flags produce unintended payment gateway behaviour.

```elixir
defmodule Payments.GatewayAdapter do
  @moduledoc """
  Adapter layer for the payment gateway integration.
  Translates internal charge requests into gateway API calls,
  handles idempotency, and normalises gateway responses.
  """

  require Logger

  @supported_currencies ~w(USD EUR GBP BRL)
  @max_amount_cents 10_000_000

  @type charge_request :: %{
          amount_cents: pos_integer(),
          currency: String.t(),
          payment_method_id: String.t(),
          customer_id: String.t(),
          optional(:idempotency_key) => String.t(),
          optional(:descriptor) => String.t(),
          optional(:capture_immediately) => boolean(),
          optional(:metadata) => map()
        }

  @type gateway_response :: %{
          charge_id: String.t(),
          status: :captured | :authorized | :failed,
          amount_cents: pos_integer(),
          currency: String.t(),
          captured: boolean(),
          gateway_message: String.t()
        }

  @spec charge(charge_request()) ::
          {:ok, gateway_response()} | {:error, String.t()}
  def charge(request) do
    with :ok <- validate_request(request),
         {:ok, payload} <- build_payload(request),
         {:ok, response} <- call_gateway(payload) do
      {:ok, normalise_response(response)}
    end
  end

  defp validate_request(request) do
    cond do
      request.amount_cents <= 0 ->
        {:error, "amount must be positive"}

      request.amount_cents > @max_amount_cents ->
        {:error, "amount exceeds maximum of #{@max_amount_cents} cents"}

      request.currency not in @supported_currencies ->
        {:error, "unsupported currency: #{request.currency}"}

      true ->
        :ok
    end
  end

  defp build_payload(request) do
    # VALIDATION: SMELL START - Accessing non-existent Map/Struct fields
    # VALIDATION: This is a smell because `request[:idempotency_key]`,
    # `request[:descriptor]`, and `request[:capture_immediately]` use dynamic
    # bracket access on a plain map. When these keys are absent, all three
    # return `nil`. A `nil` idempotency key means the gateway call proceeds
    # without deduplication protection — but the code cannot distinguish
    # "caller deliberately omitted the key" from "key was accidentally dropped".
    # Similarly, `nil` capture flag is silently coerced to false.
    idempotency_key    = request[:idempotency_key]
    descriptor         = request[:descriptor]
    capture_immediately = request[:capture_immediately]
    # VALIDATION: SMELL END

    payload = %{
      amount:            request.amount_cents,
      currency:          request.currency,
      payment_method:    request.payment_method_id,
      customer:          request.customer_id,
      capture:           capture_immediately || false,
      statement_descriptor: descriptor || "CHARGE",
      metadata:          Map.get(request, :metadata, %{})
    }

    payload =
      if idempotency_key do
        Map.put(payload, :idempotency_key, idempotency_key)
      else
        Logger.warning("Charge for customer=#{request.customer_id} has no idempotency key")
        payload
      end

    {:ok, payload}
  end

  defp call_gateway(payload) do
    Logger.info("Calling payment gateway: amount=#{payload.amount} currency=#{payload.currency}")

    simulated_response = %{
      "id"       => "ch_" <> Base.encode16(:crypto.strong_rand_bytes(8)),
      "status"   => "succeeded",
      "captured" => payload.capture,
      "amount"   => payload.amount,
      "currency" => payload.currency,
      "outcome"  => %{"message" => "Payment complete."}
    }

    {:ok, simulated_response}
  end

  defp normalise_response(raw) do
    status =
      case raw["status"] do
        "succeeded" -> if raw["captured"], do: :captured, else: :authorized
        _           -> :failed
      end

    %{
      charge_id:       raw["id"],
      status:          status,
      amount_cents:    raw["amount"],
      currency:        raw["currency"],
      captured:        raw["captured"],
      gateway_message: get_in(raw, ["outcome", "message"]) || ""
    }
  end

  @spec refund(String.t(), pos_integer()) :: {:ok, map()} | {:error, String.t()}
  def refund(charge_id, amount_cents) when amount_cents > 0 do
    Logger.info("Refunding charge=#{charge_id} amount=#{amount_cents}")
    refund_record = %{refund_id: "re_" <> charge_id, charge_id: charge_id,
                      amount_cents: amount_cents, created_at: DateTime.utc_now()}
    {:ok, refund_record}
  end

  def refund(_, _), do: {:error, "refund amount must be positive"}
end
```
