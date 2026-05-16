```elixir
defmodule Billing.ChargeProcessor do
  @moduledoc """
  Processes customer charges by coordinating with the payment provider API.
  Handles the full lifecycle of a charge from invoice validation to receipt
  generation.
  """

  require Logger

  alias Billing.{Customer, Invoice, Receipt}
  alias Billing.Repo
  alias Billing.Events

  @charge_timeout 15_000
  @supported_currencies ~w(usd eur gbp brl)

  def process_invoice(invoice_id) do
    with {:ok, invoice} <- Invoice.fetch(invoice_id),
         {:ok, customer} <- Customer.fetch(invoice.customer_id),
         :ok <- validate_invoice(invoice),
         :ok <- validate_currency(invoice.currency),
         {:ok, result} <- create_charge(customer, invoice) do
      finalize_invoice(invoice, result)
    else
      {:error, :invoice_not_found} ->
        Logger.warning("Invoice #{invoice_id} not found")
        {:error, :not_found}

      {:error, reason} ->
        Logger.error("Failed to process invoice #{invoice_id}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  def retry_failed_charge(invoice_id) do
    with {:ok, invoice} <- Invoice.fetch(invoice_id),
         :ok <- ensure_retryable(invoice) do
      process_invoice(invoice_id)
    end
  end

  defp validate_invoice(%Invoice{status: "draft"}), do: {:error, :invoice_not_finalized}
  defp validate_invoice(%Invoice{status: "paid"}), do: {:error, :already_paid}
  defp validate_invoice(%Invoice{status: "void"}), do: {:error, :invoice_voided}
  defp validate_invoice(%Invoice{amount: 0}), do: {:error, :zero_amount}
  defp validate_invoice(%Invoice{amount: a}) when a < 0, do: {:error, :negative_amount}
  defp validate_invoice(_invoice), do: :ok

  defp validate_currency(currency) when currency in @supported_currencies, do: :ok
  defp validate_currency(c), do: {:error, {:unsupported_currency, c}}

  defp ensure_retryable(%Invoice{status: "failed"}), do: :ok
  defp ensure_retryable(_), do: {:error, :not_retryable}

  defp create_charge(%Customer{} = customer, %Invoice{} = invoice) do
    params = %{
      customer_id: customer.external_id,
      payment_method: customer.default_payment_method_id,
      amount: invoice.amount,
      currency: invoice.currency,
      description: "Invoice #{invoice.number}",
      metadata: %{
        invoice_id: invoice.id,
        customer_id: customer.id,
        invoice_number: invoice.number
      }
    }

    PaymentProvider.Charges.create(params, timeout: @charge_timeout)
    |> handle_charge_response()
  end

  defp handle_charge_response(response) do
    case response do
      {:ok, %{status: "succeeded", id: charge_id, receipt_url: url}} ->
        {:ok, %{charge_id: charge_id, receipt_url: url}}

      {:ok, %{status: "pending", id: charge_id}} ->
        Logger.info("Charge #{charge_id} pending authorization")
        {:pending, charge_id}

      {:ok, %{status: "failed", failure_code: "card_declined", failure_message: msg}} ->
        Logger.warning("Card declined for charge: #{msg}")
        {:error, {:card_declined, msg}}

      {:ok, %{status: "failed", failure_code: "insufficient_funds"}} ->
        {:error, :insufficient_funds}

      {:ok, %{status: "failed", failure_code: "expired_card"}} ->
        {:error, :expired_card}

      {:ok, %{status: "failed", failure_code: "do_not_honor"}} ->
        {:error, :do_not_honor}

      {:ok, %{status: "failed", failure_code: "lost_card"}} ->
        Logger.warning("Charge attempted on reported lost card")
        {:error, :lost_card}

      {:ok, %{status: "failed", failure_code: "stolen_card"}} ->
        Logger.warning("Charge attempted on reported stolen card")
        {:error, :stolen_card}

      {:ok, %{status: "failed", failure_code: code}} ->
        Logger.error("Unhandled charge failure code: #{code}")
        {:error, {:charge_failed, code}}

      {:error, %{type: "rate_limit_error"}} ->
        Logger.warning("Payment provider rate limit reached")
        {:error, :rate_limited}

      {:error, %{type: "authentication_error"}} ->
        Logger.error("Payment provider authentication failure")
        {:error, :provider_auth_failed}

      {:error, %{type: "api_connection_error", message: msg}} ->
        Logger.error("Payment provider unreachable: #{msg}")
        {:error, :provider_unavailable}

      {:error, %{type: "invalid_request_error", param: param}} ->
        Logger.error("Invalid parameter sent to provider: #{param}")
        {:error, {:invalid_param, param}}

      {:error, reason} ->
        Logger.error("Unexpected provider response: #{inspect(reason)}")
        {:error, {:unexpected, reason}}
    end
  end

  defp finalize_invoice(invoice, %{charge_id: charge_id, receipt_url: url}) do
    Repo.transaction(fn ->
      invoice
      |> Invoice.mark_paid(%{charge_id: charge_id, paid_at: DateTime.utc_now()})
      |> Repo.update!()

      Receipt.create!(%{
        invoice_id: invoice.id,
        charge_id: charge_id,
        receipt_url: url,
        issued_at: DateTime.utc_now()
      })

      Events.emit(:invoice_paid, %{invoice_id: invoice.id, charge_id: charge_id})
    end)
  end
end
```
