# Annotated Example 30

- **Smell name:** Complex Branching
- **Expected smell location:** `process_payment/2` function, lines with the nested `case` construct
- **Affected function(s):** `process_payment/2`
- **Short explanation:** The function uses a deeply nested `case` expression to handle every possible response variant from a single payment gateway API call — authorization failures, network errors, fraud flags, card declines, insufficient funds, and success — all within one function body. This inflates cyclomatic complexity and makes the function hard to maintain, test, and extend.

```elixir
defmodule Billing.PaymentProcessor do
  @moduledoc """
  Handles payment processing through the external payment gateway.
  Supports charge, refund, and void operations.
  """

  require Logger

  alias Billing.Gateway.Client
  alias Billing.Repo
  alias Billing.Schema.{PaymentRecord, Invoice}

  @max_retry_attempts 3
  @supported_currencies ~w(USD EUR GBP BRL)

  def charge(invoice_id, payment_method, opts \\ []) do
    currency = Keyword.get(opts, :currency, "USD")

    with {:ok, invoice} <- fetch_invoice(invoice_id),
         :ok <- validate_currency(currency),
         {:ok, token} <- tokenize_payment_method(payment_method) do
      process_payment(invoice, %{token: token, currency: currency})
    end
  end

  defp fetch_invoice(invoice_id) do
    case Repo.get(Invoice, invoice_id) do
      nil -> {:error, :invoice_not_found}
      invoice -> {:ok, invoice}
    end
  end

  defp validate_currency(currency) when currency in @supported_currencies, do: :ok
  defp validate_currency(_), do: {:error, :unsupported_currency}

  defp tokenize_payment_method(%{type: "card", number: number, expiry: expiry, cvv: cvv}) do
    Client.tokenize(%{number: number, expiry: expiry, cvv: cvv})
  end

  defp tokenize_payment_method(%{type: "bank_account", routing: r, account: a}) do
    Client.tokenize(%{routing: r, account: a})
  end

  # VALIDATION: SMELL START - Complex Branching
  # VALIDATION: This is a smell because a single function handles all possible
  # response types from one gateway API call using a deeply nested case with
  # many arms, increasing cyclomatic complexity and making the function hard
  # to understand, test, and maintain independently for each response type.
  defp process_payment(invoice, payment_params) do
    case Client.post("/charges", %{
           amount: invoice.amount_cents,
           currency: payment_params.currency,
           token: payment_params.token,
           idempotency_key: invoice.idempotency_key
         }) do
      {:ok, %{status: 201, body: %{"charge_id" => charge_id, "status" => "captured"}}} ->
        Logger.info("Payment captured for invoice #{invoice.id}, charge #{charge_id}")

        {:ok, record} =
          Repo.insert(%PaymentRecord{
            invoice_id: invoice.id,
            charge_id: charge_id,
            amount_cents: invoice.amount_cents,
            currency: payment_params.currency,
            status: :captured
          })

        {:ok, record}

      {:ok, %{status: 201, body: %{"charge_id" => charge_id, "status" => "pending"}}} ->
        Logger.info("Payment pending for invoice #{invoice.id}, charge #{charge_id}")

        {:ok, record} =
          Repo.insert(%PaymentRecord{
            invoice_id: invoice.id,
            charge_id: charge_id,
            amount_cents: invoice.amount_cents,
            currency: payment_params.currency,
            status: :pending
          })

        {:ok, record}

      {:ok, %{status: 402, body: %{"error" => %{"code" => "insufficient_funds"}}}} ->
        Logger.warning("Insufficient funds for invoice #{invoice.id}")
        {:error, :insufficient_funds}

      {:ok, %{status: 402, body: %{"error" => %{"code" => "card_declined"}}}} ->
        Logger.warning("Card declined for invoice #{invoice.id}")
        {:error, :card_declined}

      {:ok, %{status: 402, body: %{"error" => %{"code" => "expired_card"}}}} ->
        Logger.warning("Expired card on invoice #{invoice.id}")
        {:error, :expired_card}

      {:ok, %{status: 403, body: %{"error" => %{"code" => "fraud_detected"}}}} ->
        Logger.error("Fraud detected on invoice #{invoice.id}, blocking payment method")
        {:error, :fraud_detected}

      {:ok, %{status: 422, body: %{"error" => %{"code" => "invalid_token"}}}} ->
        Logger.warning("Invalid payment token for invoice #{invoice.id}")
        {:error, :invalid_token}

      {:ok, %{status: 429, body: _}} ->
        Logger.warning("Rate limited by gateway on invoice #{invoice.id}")
        {:error, :rate_limited}

      {:ok, %{status: status, body: body}} ->
        Logger.error("Unexpected gateway response #{status} for invoice #{invoice.id}: #{inspect(body)}")
        {:error, {:unexpected_response, status}}

      {:error, %{reason: :timeout}} ->
        Logger.error("Gateway timeout on invoice #{invoice.id}")
        {:error, :gateway_timeout}

      {:error, %{reason: :econnrefused}} ->
        Logger.error("Gateway connection refused on invoice #{invoice.id}")
        {:error, :gateway_unavailable}

      {:error, reason} ->
        Logger.error("Gateway network error on invoice #{invoice.id}: #{inspect(reason)}")
        {:error, {:network_error, reason}}
    end
  end
  # VALIDATION: SMELL END

  def refund(charge_id, amount_cents, reason \\ "requested_by_customer") do
    case Client.post("/refunds", %{charge_id: charge_id, amount: amount_cents, reason: reason}) do
      {:ok, %{status: 201, body: body}} -> {:ok, body}
      {:ok, %{status: _, body: body}} -> {:error, body}
      {:error, _} = err -> err
    end
  end

  def void(charge_id) do
    case Client.post("/voids", %{charge_id: charge_id}) do
      {:ok, %{status: 200, body: body}} -> {:ok, body}
      {:ok, %{status: _, body: body}} -> {:error, body}
      {:error, _} = err -> err
    end
  end

  defp retry(fun, attempts \\ @max_retry_attempts)
  defp retry(_fun, 0), do: {:error, :max_retries_exceeded}

  defp retry(fun, attempts) do
    case fun.() do
      {:error, :gateway_timeout} -> retry(fun, attempts - 1)
      {:error, :gateway_unavailable} -> retry(fun, attempts - 1)
      other -> other
    end
  end
end
```
