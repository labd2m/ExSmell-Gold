# Annotated Example 27 — Modules with Identical Names

## Metadata

- **Smell name:** Modules with identical names
- **Expected smell location:** Both `defmodule Payments.Gateway` declarations
- **Affected functions:** `Payments.Gateway.charge/3`, `Payments.Gateway.refund/2`, `Payments.Gateway.capture/2`, `Payments.Gateway.void/1`, `Payments.Gateway.status/1`
- **Short explanation:** Two source files both declare `defmodule Payments.Gateway`. The BEAM VM loads only one module definition per name; the later-compiled file silently replaces the earlier one, making any function defined only in the first module permanently inaccessible — a severe issue in a payment processing context.

---

```elixir
# ── file: lib/payments/gateway.ex ───────────────────────────────────────────

# VALIDATION: SMELL START - Modules with identical names
# VALIDATION: This is a smell because `Payments.Gateway` is declared here and
# again in a second block below. BEAM will discard one definition entirely,
# leading to missing payment functions and potential financial data loss.

defmodule Payments.Gateway do
  @moduledoc """
  Adapter to the external payment processing gateway.
  Handles charge, refund, capture, and void operations.
  Defined in `lib/payments/gateway.ex`.
  """

  alias Payments.{HttpClient, ResponseParser, IdempotencyKey, TransactionLog}

  @base_url Application.compile_env(:my_app, [:payment_gateway, :base_url], "https://pay.example.com")
  @timeout_ms 10_000

  @type transaction_id :: String.t()
  @type amount_cents :: pos_integer()
  @type currency :: String.t()

  @type charge_result ::
          {:ok, %{transaction_id: transaction_id(), status: atom()}}
          | {:error, String.t()}

  @doc """
  Charge a payment method for the given amount.
  `payment_method_id` is the tokenized representation of the customer's card.
  """
  @spec charge(String.t(), amount_cents(), currency()) :: charge_result()
  def charge(payment_method_id, amount_cents, currency \\ "USD")
      when is_binary(payment_method_id) and is_integer(amount_cents) and amount_cents > 0 do
    idempotency_key = IdempotencyKey.generate(payment_method_id, amount_cents)

    body = %{
      payment_method: payment_method_id,
      amount: amount_cents,
      currency: String.upcase(currency),
      capture: true
    }

    with {:ok, response} <- post("/charges", body, idempotency_key),
         {:ok, parsed} <- ResponseParser.parse(response) do
      TransactionLog.record(:charge, parsed)
      {:ok, parsed}
    else
      {:error, reason} -> {:error, "Charge failed: #{reason}"}
    end
  end

  @doc "Refund a previously completed charge, in whole or in part."
  @spec refund(transaction_id(), amount_cents() | :full) ::
          {:ok, map()} | {:error, String.t()}
  def refund(transaction_id, :full) do
    post("/charges/#{transaction_id}/refunds", %{})
    |> handle_response(:refund, transaction_id)
  end

  def refund(transaction_id, amount_cents) when is_integer(amount_cents) and amount_cents > 0 do
    post("/charges/#{transaction_id}/refunds", %{amount: amount_cents})
    |> handle_response(:refund, transaction_id)
  end

  @doc "Capture a previously authorized (un-captured) charge."
  @spec capture(transaction_id(), amount_cents() | nil) ::
          {:ok, map()} | {:error, String.t()}
  def capture(transaction_id, amount_cents \\ nil) do
    body = if amount_cents, do: %{amount: amount_cents}, else: %{}

    post("/charges/#{transaction_id}/capture", body)
    |> handle_response(:capture, transaction_id)
  end

  @doc "Void an authorized but not-yet-captured charge."
  @spec void(transaction_id()) :: {:ok, map()} | {:error, String.t()}
  def void(transaction_id) do
    post("/charges/#{transaction_id}/void", %{})
    |> handle_response(:void, transaction_id)
  end

  @doc "Fetch the current status of a transaction from the gateway."
  @spec status(transaction_id()) :: {:ok, atom()} | {:error, String.t()}
  def status(transaction_id) do
    with {:ok, response} <- get("/charges/#{transaction_id}"),
         {:ok, %{status: s}} <- ResponseParser.parse(response) do
      {:ok, String.to_atom(s)}
    else
      {:error, reason} -> {:error, "Status check failed: #{reason}"}
    end
  end

  defp post(path, body, idempotency_key \\ nil) do
    headers = build_headers(idempotency_key)
    HttpClient.post(@base_url <> path, body, headers, timeout: @timeout_ms)
  end

  defp get(path) do
    HttpClient.get(@base_url <> path, build_headers(), timeout: @timeout_ms)
  end

  defp build_headers(idempotency_key \\ nil) do
    base = [{"Authorization", "Bearer #{api_key()}"}, {"Content-Type", "application/json"}]
    if idempotency_key, do: [{"Idempotency-Key", idempotency_key} | base], else: base
  end

  defp handle_response(result, event_type, tx_id) do
    with {:ok, response} <- result,
         {:ok, parsed} <- ResponseParser.parse(response) do
      TransactionLog.record(event_type, Map.put(parsed, :original_tx, tx_id))
      {:ok, parsed}
    else
      {:error, reason} -> {:error, "#{event_type} failed for #{tx_id}: #{reason}"}
    end
  end

  defp api_key, do: Application.fetch_env!(:my_app, [:payment_gateway, :api_key])
end

# VALIDATION: SMELL END

# ── file: lib/payments/gateway_webhooks.ex  (webhook handling was added in a
#    separate file but the developer reused the gateway module name) ──────────

# VALIDATION: SMELL START - Modules with identical names
# VALIDATION: This second `defmodule Payments.Gateway` replaces the first.
# Functions like `charge/3`, `refund/2`, `capture/2`, `void/1`, and `status/1`
# vanish from BEAM's loaded modules, causing catastrophic payment failures.

defmodule Payments.Gateway do
  @moduledoc """
  Inbound webhook processing for payment gateway events.
  Should have been named `Payments.Gateway.Webhooks` but was accidentally
  given the same module name as the core gateway adapter.
  """

  alias Payments.{WebhookVerifier, TransactionLog}

  @doc "Verify and dispatch an inbound gateway webhook event."
  @spec handle_webhook(map(), String.t()) :: :ok | {:error, String.t()}
  def handle_webhook(payload, signature) do
    with :ok <- WebhookVerifier.verify(payload, signature) do
      process_event(payload["type"], payload["data"])
    end
  end

  defp process_event("charge.succeeded", data) do
    TransactionLog.record(:charge_confirmed, %{
      transaction_id: data["id"],
      amount: data["amount"],
      currency: data["currency"]
    })
  end

  defp process_event("charge.failed", data) do
    TransactionLog.record(:charge_failed, %{
      transaction_id: data["id"],
      failure_code: data["failure_code"],
      failure_message: data["failure_message"]
    })
  end

  defp process_event("refund.created", data) do
    TransactionLog.record(:refund_initiated, %{
      refund_id: data["id"],
      charge_id: data["charge"],
      amount: data["amount"]
    })
  end

  defp process_event("dispute.created", data) do
    Payments.DisputeManager.open(%{
      dispute_id: data["id"],
      charge_id: data["charge"],
      amount: data["amount"],
      reason: data["reason"]
    })
  end

  defp process_event(unknown_type, _data) do
    {:error, "Unhandled gateway event type: #{unknown_type}"}
  end
end

# VALIDATION: SMELL END
```
