```elixir
defmodule Billing.InvoiceBuilder do
  @moduledoc """
  Builds and formats invoices for billing operations.
  """

  alias Billing.{Customer, InvoiceLine, TaxCalculator, PdfRenderer}
  require Logger

  @default_due_days 30
  @max_credit_utilization 0.90

  def create_invoice(attrs) do
    with {:ok, lines} <- validate_lines(attrs[:lines]),
         {:ok, tax_info} <- TaxCalculator.compute(lines, attrs[:region]),
         {:ok, invoice} <- persist_invoice(attrs, lines, tax_info) do
      {:ok, invoice}
    end
  end

  def add_line_item(invoice, description, quantity, unit_price) do
    line = InvoiceLine.build(description, quantity, unit_price)
    updated_lines = [line | invoice.lines]
    subtotal = Enum.reduce(updated_lines, 0, &(&1.total + &2))
    %{invoice | lines: updated_lines, subtotal: subtotal}
  end

  def finalize_invoice(invoice) do
    tax = TaxCalculator.compute_total(invoice.lines, invoice.tax_rate)
    total = invoice.subtotal + tax
    %{invoice | tax: tax, total: total, status: :finalized}
  end

  def void_invoice(invoice, reason) do
    Logger.info("Voiding invoice #{invoice.id}: #{reason}")
    %{invoice | status: :void, void_reason: reason, voided_at: DateTime.utc_now()}
  end

  def apply_credit_note(invoice, credit_amount) do
    adjusted = max(invoice.total - credit_amount, 0)
    %{invoice | total: adjusted, credit_applied: credit_amount}
  end

  def build_customer_billing_summary(customer_id) do
    customer = Customer.get!(customer_id)

    full_name = "#{customer.first_name} #{customer.last_name}"
    address = "#{customer.street}, #{customer.city}, #{customer.state} #{customer.zip}"

    tax_classification = Customer.tax_classification(customer)
    credit_limit = Customer.credit_limit(customer)
    outstanding = Customer.outstanding_balance(customer)
    available_credit = credit_limit - outstanding
    utilization = if credit_limit > 0, do: outstanding / credit_limit, else: 0.0

    payment_terms = Customer.payment_terms(customer)
    net_days = Map.get(payment_terms, :net_days, @default_due_days)

    overdue_count = Customer.overdue_invoice_count(customer)

    risk_flag =
      cond do
        overdue_count > 3 -> :high_risk
        utilization >= @max_credit_utilization -> :near_limit
        true -> :good_standing
      end

    %{
      name: full_name,
      email: customer.email,
      phone: customer.phone,
      address: address,
      tax_id: customer.tax_id,
      tax_classification: tax_classification,
      account_number: customer.account_number,
      preferred_currency: customer.preferred_currency,
      credit_limit: credit_limit,
      available_credit: available_credit,
      credit_utilization: Float.round(utilization * 100, 2),
      net_payment_days: net_days,
      overdue_invoices: overdue_count,
      risk_flag: risk_flag
    }
  end

  def generate_pdf(invoice, customer_id) do
    summary = build_customer_billing_summary(customer_id)
    PdfRenderer.render(invoice, summary)
  end

  def send_invoice(invoice, customer_id) do
    summary = build_customer_billing_summary(customer_id)
    Logger.info("Sending invoice #{invoice.id} to #{summary.email}")
    {:ok, %{invoice_id: invoice.id, sent_to: summary.email, sent_at: DateTime.utc_now()}}
  end

  defp validate_lines([]), do: {:error, :no_lines}
  defp validate_lines(lines) when is_list(lines), do: {:ok, lines}
  defp validate_lines(_), do: {:error, :invalid_lines}

  defp persist_invoice(attrs, lines, tax_info) do
    invoice = %{
      id: Ecto.UUID.generate(),
      customer_id: attrs[:customer_id],
      lines: lines,
      tax_rate: tax_info.rate,
      subtotal: Enum.reduce(lines, 0, &(&1.total + &2)),
      status: :draft,
      created_at: DateTime.utc_now()
    }

    {:ok, invoice}
  end
end
```
