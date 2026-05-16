```elixir
defmodule Billing.InvoiceProcessor do
  alias Billing.{Repo, Invoice, Customer, TaxCalculator, PaymentGateway}

  require Logger

  @max_invoice_amount Money.new(100_000_00, :USD)

  def process_invoice(invoice_id, operator_id) do
    with {:ok, invoice} <- fetch_invoice(invoice_id),
         {:ok, customer} <- fetch_customer(invoice.customer_id),
         {:ok, tax_info} <- TaxCalculator.compute(customer, invoice.line_items),
         {:ok, charge} <- PaymentGateway.charge(customer.payment_method, invoice.total) do
      finalize(invoice, charge, tax_info, operator_id)
    else
     
      {:error, :not_found} ->
        Logger.warning("Resource not found while processing invoice #{invoice_id}")
        {:error, :not_found}

      {:error, :tax_jurisdiction_unknown} ->
        Logger.error("Tax jurisdiction could not be resolved for invoice #{invoice_id}")
        {:error, :tax_configuration_error}

      {:error, :rate_unavailable} ->
        Logger.error("Tax rate unavailable for invoice #{invoice_id}")
        {:error, :tax_configuration_error}

      {:error, :insufficient_funds} ->
        Logger.warning("Payment declined for invoice #{invoice_id}: insufficient funds")
        mark_invoice_failed(invoice_id, :insufficient_funds)
        {:error, :payment_declined}

      {:error, :gateway_timeout} ->
        Logger.error("Payment gateway timed out for invoice #{invoice_id}")
        schedule_retry(invoice_id)
        {:error, :gateway_timeout}

      {:error, reason} ->
        Logger.error("Unexpected error processing invoice #{invoice_id}: #{inspect(reason)}")
        {:error, :internal_error}
    end
  end

  defp fetch_invoice(invoice_id) do
    case Repo.get(Invoice, invoice_id) do
      nil -> {:error, :not_found}
      invoice -> {:ok, invoice}
    end
  end

  defp fetch_customer(customer_id) do
    case Repo.get(Customer, customer_id) do
      nil -> {:error, :not_found}
      customer -> {:ok, customer}
    end
  end

  defp finalize(invoice, charge, tax_info, operator_id) do
    invoice
    |> Invoice.changeset(%{
      status: :paid,
      charge_id: charge.id,
      tax_amount: tax_info.total_tax,
      processed_by: operator_id,
      processed_at: DateTime.utc_now()
    })
    |> Repo.update()
  end

  defp mark_invoice_failed(invoice_id, reason) do
    case Repo.get(Invoice, invoice_id) do
      nil ->
        :ok

      invoice ->
        invoice
        |> Invoice.changeset(%{status: :failed, failure_reason: to_string(reason)})
        |> Repo.update()
    end
  end

  defp schedule_retry(invoice_id) do
    %{invoice_id: invoice_id}
    |> Billing.RetryWorker.new(schedule_in: 300)
    |> Oban.insert()
  end

  defp validate_amount(invoice) do
    if Money.compare(invoice.total, @max_invoice_amount) == :gt do
      {:error, :amount_exceeds_limit}
    else
      {:ok, invoice}
    end
  end
end
```
