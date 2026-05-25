# Example Bad 01 — Annotated

## Metadata

- **Smell Name**: Speculative Generality
- **Expected Smell Location**: `Billing.InvoiceGenerator.generate_invoice/2`
- **Affected Function(s)**: `generate_invoice/2`
- **Explanation**: The `output_format` parameter is defined with a default value of `:pdf`
  to accommodate possible future formats such as `:html` or `:csv`. In practice, every
  internal call site — `regenerate/1`, `bulk_generate/1`, and every external caller —
  always omits the second argument, meaning `:pdf` is the only format ever in use.
  The parameter was added speculatively and contributes no real flexibility.

## Code

```elixir
defmodule Billing.InvoiceGenerator do
  @moduledoc """
  Generates customer invoices and dispatches them via email.
  Supports invoice creation for all active orders in the billing pipeline.
  """

  alias Billing.{Invoice, LineItem, Customer}
  alias Billing.Repo
  alias Notifications.Mailer

  @tax_rate 0.10
  @default_payment_terms 30
  @late_penalty_rate 0.015

  # VALIDATION: SMELL START - Speculative Generality
  # VALIDATION: This is a smell because `output_format \\ :pdf` was added
  # speculatively to support future invoice formats (e.g. :html, :csv), but
  # every call site—regenerate/1, bulk_generate/1, and external callers—always
  # omits the second argument. The parameter has never been exercised with any
  # value other than its default.
  def generate_invoice(order, output_format \\ :pdf) do
  # VALIDATION: SMELL END
    customer   = Customer.get!(order.customer_id)
    line_items = build_line_items(order.items)
    subtotal   = compute_subtotal(line_items)
    tax        = Float.round(subtotal * @tax_rate, 2)
    total      = Float.round(subtotal + tax, 2)
    due_date   = Date.add(Date.utc_today(), @default_payment_terms)

    attrs = %{
      customer_id:   customer.id,
      order_id:      order.id,
      line_items:    line_items,
      subtotal:      subtotal,
      tax:           tax,
      total:         total,
      due_date:      due_date,
      output_format: output_format,
      status:        :pending,
      issued_at:     Date.utc_today()
    }

    case Invoice.changeset(%Invoice{}, attrs) |> Repo.insert() do
      {:ok, invoice} ->
        Mailer.send_invoice(customer.email, invoice)
        {:ok, invoice}

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  def regenerate(order) do
    generate_invoice(order)
  end

  def bulk_generate(orders) when is_list(orders) do
    Enum.reduce(orders, {[], []}, fn order, {ok_list, err_list} ->
      case generate_invoice(order) do
        {:ok, inv}  -> {[inv | ok_list], err_list}
        {:error, e} -> {ok_list, [e | err_list]}
      end
    end)
  end

  def cancel_invoice(invoice_id) do
    invoice = Repo.get!(Invoice, invoice_id)

    invoice
    |> Invoice.changeset(%{status: :cancelled, cancelled_at: DateTime.utc_now()})
    |> Repo.update()
  end

  def apply_late_penalty(invoice_id) do
    invoice   = Repo.get!(Invoice, invoice_id)
    penalty   = Float.round(invoice.total * @late_penalty_rate, 2)
    new_total = Float.round(invoice.total + penalty, 2)

    invoice
    |> Invoice.changeset(%{total: new_total, penalty_applied: true})
    |> Repo.update()
  end

  def mark_paid(invoice_id, payment_ref) do
    invoice = Repo.get!(Invoice, invoice_id)

    invoice
    |> Invoice.changeset(%{
      status:      :paid,
      payment_ref: payment_ref,
      paid_at:     DateTime.utc_now()
    })
    |> Repo.update()
  end

  def list_overdue do
    today = Date.utc_today()

    Invoice
    |> Repo.all()
    |> Enum.filter(fn inv ->
      inv.status == :pending and Date.compare(inv.due_date, today) == :lt
    end)
  end

  def revenue_summary(from_date, to_date) do
    Invoice
    |> Repo.all()
    |> Enum.filter(fn inv ->
      inv.status == :paid and
        Date.compare(inv.paid_at, from_date) in [:gt, :eq] and
        Date.compare(inv.paid_at, to_date) in [:lt, :eq]
    end)
    |> Enum.reduce(%{count: 0, total: 0.0}, fn inv, acc ->
      %{acc | count: acc.count + 1, total: acc.total + inv.total}
    end)
    |> Map.update!(:total, &Float.round(&1, 2))
  end

  # --- Private ---

  defp build_line_items(items) do
    Enum.map(items, fn item ->
      %LineItem{
        product_id:  item.product_id,
        description: item.description,
        quantity:    item.quantity,
        unit_price:  item.unit_price,
        line_total:  Float.round(item.quantity * item.unit_price, 2)
      }
    end)
  end

  defp compute_subtotal(line_items) do
    line_items
    |> Enum.reduce(0.0, fn li, acc -> acc + li.line_total end)
    |> Float.round(2)
  end
end
```
