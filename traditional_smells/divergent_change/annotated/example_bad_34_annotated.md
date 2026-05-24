# Annotated Example — Divergent Change

## Metadata

- **Smell name:** Divergent Change
- **Expected smell location:** `InvoiceService` module (entire module)
- **Affected functions:** `generate_invoice/2`, `void_invoice/2`, `compute_tax/2`, `apply_tax_exemption/2`, `email_invoice/2`, `upload_invoice_pdf/2`
- **Explanation:** `InvoiceService` combines invoice document creation/voiding, tax computation and exemption handling, and invoice delivery (email + PDF storage). Each area has an independent reason to change — invoice data structure may change with legal requirements, tax rules with jurisdiction updates, and delivery channels with infrastructure changes.

---

```elixir
defmodule MyApp.InvoiceService do
  @moduledoc """
  Handles invoice generation and voiding, tax calculation and exemptions,
  and invoice delivery to customers.
  """

  alias MyApp.Repo
  alias MyApp.Schemas.{Invoice, InvoiceLine, TaxExemption}
  alias MyApp.Integrations.{Mailer, S3, PDFRenderer}
  import Ecto.Query

  # VALIDATION: SMELL START - Divergent Change
  # VALIDATION: This is a smell because invoice lifecycle (generate/void),
  # tax logic (compute/exempt), and invoice delivery (email/PDF upload) are
  # three unrelated concerns in one module. Changes in accounting regulations,
  # tax jurisdiction rules, or delivery infrastructure each affect
  # independent parts of this module.

  ## ── Invoice Lifecycle ───────────────────────────────────────────────────────

  @doc """
  Generates an invoice for a customer with the given line items.
  Computes totals and persists the invoice with its lines.
  """
  def generate_invoice(customer_id, line_items) do
    subtotal = Enum.sum(Enum.map(line_items, & &1.amount_cents))
    tax_cents = compute_tax(customer_id, subtotal)
    total = subtotal + tax_cents

    Repo.transaction(fn ->
      invoice =
        %Invoice{}
        |> Invoice.changeset(%{
          customer_id: customer_id,
          subtotal_cents: subtotal,
          tax_cents: tax_cents,
          total_cents: total,
          status: :open,
          invoice_number: generate_number(),
          issued_at: DateTime.utc_now(),
          due_at: DateTime.add(DateTime.utc_now(), 30 * 86_400, :second)
        })
        |> Repo.insert!()

      Enum.each(line_items, fn item ->
        %InvoiceLine{}
        |> InvoiceLine.changeset(Map.put(item, :invoice_id, invoice.id))
        |> Repo.insert!()
      end)

      invoice
    end)
  end

  @doc """
  Voids an invoice that has not yet been paid.
  """
  def void_invoice(%Invoice{status: :paid}, _reason), do: {:error, :cannot_void_paid}

  def void_invoice(%Invoice{} = invoice, reason) do
    invoice
    |> Invoice.changeset(%{
      status: :void,
      void_reason: reason,
      voided_at: DateTime.utc_now()
    })
    |> Repo.update()
  end

  defp generate_number do
    "INV-#{:os.system_time(:millisecond)}"
  end

  ## ── Tax Calculation ──────────────────────────────────────────────────────────

  @doc """
  Computes applicable tax in cents for a given customer and subtotal.
  Respects any active tax exemption for the customer.
  """
  def compute_tax(customer_id, subtotal_cents) do
    case Repo.get_by(TaxExemption, customer_id: customer_id, active: true) do
      %TaxExemption{} ->
        0

      nil ->
        customer = MyApp.Customers.get!(customer_id)
        rate = jurisdiction_rate(customer.country, customer.state)
        round(subtotal_cents * rate)
    end
  end

  @doc """
  Records a tax exemption certificate for a customer.
  """
  def apply_tax_exemption(customer_id, certificate_number) do
    existing = Repo.get_by(TaxExemption, customer_id: customer_id)

    changeset_attrs = %{
      customer_id: customer_id,
      certificate_number: certificate_number,
      active: true,
      applied_at: DateTime.utc_now()
    }

    case existing do
      nil ->
        %TaxExemption{} |> TaxExemption.changeset(changeset_attrs) |> Repo.insert()

      record ->
        record |> TaxExemption.changeset(changeset_attrs) |> Repo.update()
    end
  end

  defp jurisdiction_rate("US", "CA"), do: 0.0725
  defp jurisdiction_rate("US", "TX"), do: 0.0825
  defp jurisdiction_rate("US", _), do: 0.06
  defp jurisdiction_rate(_, _), do: 0.20

  ## ── Delivery ─────────────────────────────────────────────────────────────────

  @doc """
  Renders the invoice as a PDF and emails it to the customer.
  """
  def email_invoice(%Invoice{} = invoice, recipient_email) do
    customer = MyApp.Customers.get!(invoice.customer_id)
    lines = Repo.all(from l in InvoiceLine, where: l.invoice_id == ^invoice.id)

    {:ok, pdf_binary} = PDFRenderer.render_invoice(invoice, customer, lines)

    Mailer.send(%{
      to: recipient_email,
      subject: "Invoice #{invoice.invoice_number}",
      text_body: "Please find your invoice attached.",
      attachments: [
        %{filename: "#{invoice.invoice_number}.pdf", content: Base.encode64(pdf_binary)}
      ]
    })
  end

  @doc """
  Uploads the rendered invoice PDF to S3 for archival.
  """
  def upload_invoice_pdf(%Invoice{} = invoice) do
    customer = MyApp.Customers.get!(invoice.customer_id)
    lines = Repo.all(from l in InvoiceLine, where: l.invoice_id == ^invoice.id)

    {:ok, pdf_binary} = PDFRenderer.render_invoice(invoice, customer, lines)
    key = "invoices/#{invoice.customer_id}/#{invoice.invoice_number}.pdf"

    S3.put_object(key, pdf_binary)
  end

  # VALIDATION: SMELL END
end
```
