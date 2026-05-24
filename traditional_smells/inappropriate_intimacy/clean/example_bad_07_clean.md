```elixir
defmodule MyApp.Billing.Invoice do
  @moduledoc """
  Handles invoice generation for customer accounts.
  Invoices are produced at the end of each billing cycle and sent to the customer.
  """

  alias MyApp.Accounts.Account
  alias MyApp.Billing.{LineItem, TaxProfile}
  alias MyApp.Mailer.InvoiceMailer

  @invoice_due_days 30

  def generate(account_id, line_items) do
    account     = Account.find(account_id)
    tax_profile = TaxProfile.for_account(account)

    billing_address = account.billing_address
    vat_number      = account.vat_number

    tax_rate    = tax_profile.rate
    tax_country = tax_profile.country_code

    subtotal = calculate_subtotal(line_items)
    tax      = Float.round(subtotal * tax_rate, 2)
    total    = subtotal + tax

    invoice = %{
      id:              generate_invoice_id(),
      account_id:      account_id,
      issued_at:       DateTime.utc_now(),
      due_at:          due_date(),
      billing_address: billing_address,
      vat_number:      vat_number,
      tax_country:     tax_country,
      tax_rate:        tax_rate,
      line_items:      line_items,
      subtotal:        subtotal,
      tax:             tax,
      total:           total,
      status:          :pending
    }

    case persist_invoice(invoice) do
      {:ok, saved} ->
        InvoiceMailer.deliver(saved)
        {:ok, saved}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def mark_paid(invoice_id, payment_reference) do
    case fetch_invoice(invoice_id) do
      nil ->
        {:error, :not_found}

      invoice ->
        updated = Map.merge(invoice, %{
          status:            :paid,
          paid_at:           DateTime.utc_now(),
          payment_reference: payment_reference
        })
        persist_invoice(updated)
    end
  end

  def void(invoice_id, reason) do
    case fetch_invoice(invoice_id) do
      nil ->
        {:error, :not_found}

      %{status: :paid} ->
        {:error, :cannot_void_paid_invoice}

      invoice ->
        updated = Map.merge(invoice, %{
          status:    :void,
          voided_at: DateTime.utc_now(),
          void_reason: reason
        })
        persist_invoice(updated)
    end
  end

  def list_for_account(account_id, opts \\ []) do
    status = Keyword.get(opts, :status)
    :ets.tab2list(:invoices)
    |> Enum.filter(fn inv -> inv.account_id == account_id end)
    |> then(fn invoices ->
      if status, do: Enum.filter(invoices, &(&1.status == status)), else: invoices
    end)
    |> Enum.sort_by(& &1.issued_at, {:desc, DateTime})
  end


  defp calculate_subtotal(line_items) do
    line_items
    |> Enum.map(&LineItem.amount/1)
    |> Enum.sum()
    |> Float.round(2)
  end

  defp due_date do
    DateTime.utc_now()
    |> DateTime.add(@invoice_due_days * 86_400, :second)
  end

  defp generate_invoice_id do
    "INV-" <> (:crypto.strong_rand_bytes(6) |> Base.encode16())
  end

  defp persist_invoice(invoice) do
    :ets.insert(:invoices, {invoice.id, invoice})
    {:ok, invoice}
  end

  defp fetch_invoice(invoice_id) do
    case :ets.lookup(:invoices, invoice_id) do
      [{_, invoice}] -> invoice
      []             -> nil
    end
  end
end
```
