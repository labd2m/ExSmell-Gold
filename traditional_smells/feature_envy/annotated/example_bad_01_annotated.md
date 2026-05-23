# Annotated Example 01: Feature Envy

## Metadata

- **Smell**: Feature Envy
- **Expected Smell Location**: `Billing.InvoicePrinter.render_customer_section/1`
- **Affected Function(s)**: `render_customer_section/1`
- **Explanation**: `render_customer_section/1` exclusively accesses functions and data
  from the `Customer` module (`Customer.full_name/1`, `Customer.billing_address/1`,
  `Customer.tax_id/1`, `Customer.locale/1`, `Customer.preferred_currency/1`). It has
  no dependency on `InvoicePrinter`'s own state or helpers, indicating it would fit
  better inside the `Customer` module.

## Code

```elixir
defmodule Billing.InvoicePrinter do
  alias Billing.{Invoice, InvoiceItem}
  alias Accounts.Customer

  @doc """
  Generates a structured invoice document ready for rendering or export.
  Accepts an invoice ID and returns a map with all sections of the document.
  """
  def generate_invoice(invoice_id) do
    invoice = Invoice.get!(invoice_id)
    items = InvoiceItem.list_for_invoice(invoice_id)
    customer = Customer.get!(invoice.customer_id)

    %{
      header: render_header(invoice),
      customer_section: render_customer_section(customer),
      line_items: Enum.map(items, &render_line_item/1),
      totals: render_totals(invoice, items),
      footer: render_footer(invoice)
    }
  end

  @doc """
  Exports the invoice as a PDF binary.
  """
  def export_pdf(invoice_id) do
    document = generate_invoice(invoice_id)
    PdfRenderer.render(document)
  end

  @doc """
  Sends the invoice by email to the customer on record.
  """
  def email_to_customer(invoice_id) do
    invoice = Invoice.get!(invoice_id)
    customer = Customer.get!(invoice.customer_id)
    pdf = export_pdf(invoice_id)

    Mailer.deliver(%{
      to: customer.email,
      subject: "Invoice #{invoice.number}",
      attachments: [%{filename: "invoice_#{invoice.number}.pdf", data: pdf}]
    })
  end

  defp render_header(invoice) do
    %{
      invoice_number: invoice.number,
      issue_date: invoice.issued_at,
      due_date: invoice.due_at,
      status: invoice.status,
      currency: invoice.currency
    }
  end

  # VALIDATION: SMELL START - Feature Envy
  # VALIDATION: This is a smell because render_customer_section/1 exclusively accesses
  # VALIDATION: functions and data from the Customer module: Customer.full_name/1,
  # VALIDATION: Customer.billing_address/1, Customer.tax_id/1, Customer.locale/1,
  # VALIDATION: and Customer.preferred_currency/1. It has no dependency on InvoicePrinter's
  # VALIDATION: own state or helpers, indicating it would fit better inside the Customer module.
  defp render_customer_section(customer) do
    full_name = Customer.full_name(customer)
    address = Customer.billing_address(customer)
    tax_id = Customer.tax_id(customer)
    locale = Customer.locale(customer)
    currency = Customer.preferred_currency(customer)

    %{
      name: full_name,
      address: %{
        street: address.street,
        city: address.city,
        state: address.state,
        zip: address.zip,
        country: address.country
      },
      tax_id: tax_id,
      locale: locale,
      currency: currency
    }
  end
  # VALIDATION: SMELL END

  defp render_line_item(item) do
    %{
      description: item.description,
      quantity: item.quantity,
      unit_price: item.unit_price,
      subtotal: item.quantity * item.unit_price,
      tax_rate: item.tax_rate,
      tax_amount: item.quantity * item.unit_price * item.tax_rate
    }
  end

  defp render_totals(invoice, items) do
    subtotal =
      Enum.reduce(items, Decimal.new(0), fn item, acc ->
        Decimal.add(acc, Decimal.mult(item.quantity, item.unit_price))
      end)

    taxes =
      Enum.reduce(items, Decimal.new(0), fn item, acc ->
        item_tax =
          Decimal.mult(
            Decimal.mult(item.quantity, item.unit_price),
            item.tax_rate
          )

        Decimal.add(acc, item_tax)
      end)

    discount = invoice.discount_amount || Decimal.new(0)

    %{
      subtotal: subtotal,
      taxes: taxes,
      discount: discount,
      total: Decimal.sub(Decimal.add(subtotal, taxes), discount)
    }
  end

  defp render_footer(invoice) do
    %{
      payment_terms: invoice.payment_terms,
      notes: invoice.notes,
      support_email: invoice.support_email,
      generated_at: DateTime.utc_now()
    }
  end
end
```
