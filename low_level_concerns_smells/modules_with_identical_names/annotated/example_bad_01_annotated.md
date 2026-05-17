# Annotated Example 01 — Modules with Identical Names

## Metadata

- **Smell name:** Modules with Identical Names
- **Expected smell location:** Two separate files both define `Billing.Invoice`
- **Affected functions:** `Billing.Invoice.build/2` (module_one) and `Billing.Invoice.mark_paid/1` (module_two)
- **Explanation:** Two modules share the exact name `Billing.Invoice`. When the BEAM loads both files, the second definition silently overwrites the first. Any function defined exclusively in the first module becomes unreachable at runtime, causing subtle and hard-to-diagnose failures.

---

```elixir
# ── file: lib/billing/invoice.ex ──────────────────────────────────────────────

defmodule Billing.Invoice do
  @moduledoc """
  Responsible for constructing new invoice records from order data.
  Used by the checkout pipeline to generate billable documents.
  """

  alias Billing.{LineItem, Customer, TaxEngine}

  @default_currency "USD"
  @default_due_days 30

  @type t :: %__MODULE__{
          id: String.t(),
          customer_id: String.t(),
          line_items: [LineItem.t()],
          currency: String.t(),
          subtotal: Decimal.t(),
          tax: Decimal.t(),
          total: Decimal.t(),
          due_date: Date.t(),
          issued_at: DateTime.t(),
          status: :draft | :issued | :paid | :void
        }

  defstruct [
    :id,
    :customer_id,
    :line_items,
    :currency,
    :subtotal,
    :tax,
    :total,
    :due_date,
    :issued_at,
    status: :draft
  ]

  # VALIDATION: SMELL START - Modules with Identical Names
  # VALIDATION: This is a smell because this module `Billing.Invoice` is defined
  # again in `lib/billing/invoice_payment.ex` with the same fully-qualified name.
  # BEAM will load both files, but only the last one compiled wins; all functions
  # defined exclusively here (e.g., `build/2`) become permanently unreachable.

  @spec build(Customer.t(), [LineItem.t()]) :: {:ok, t()} | {:error, String.t()}
  def build(%Customer{} = customer, line_items) when is_list(line_items) do
    with :ok <- validate_line_items(line_items),
         {:ok, tax_rate} <- TaxEngine.rate_for(customer.country) do
      subtotal = compute_subtotal(line_items)
      tax = Decimal.mult(subtotal, tax_rate)
      total = Decimal.add(subtotal, tax)

      invoice = %__MODULE__{
        id: generate_id(),
        customer_id: customer.id,
        line_items: line_items,
        currency: customer.preferred_currency || @default_currency,
        subtotal: subtotal,
        tax: tax,
        total: total,
        due_date: Date.add(Date.utc_today(), @default_due_days),
        issued_at: DateTime.utc_now(),
        status: :draft
      }

      {:ok, invoice}
    end
  end

  def build(_, _), do: {:error, "invalid arguments"}

  # VALIDATION: SMELL END

  @spec finalize(t()) :: {:ok, t()} | {:error, String.t()}
  def finalize(%__MODULE__{status: :draft} = invoice) do
    {:ok, %{invoice | status: :issued}}
  end

  def finalize(%__MODULE__{}), do: {:error, "only draft invoices can be finalized"}

  defp compute_subtotal(line_items) do
    Enum.reduce(line_items, Decimal.new(0), fn item, acc ->
      Decimal.add(acc, Decimal.mult(item.unit_price, item.quantity))
    end)
  end

  defp validate_line_items([]), do: {:error, "invoice must have at least one line item"}
  defp validate_line_items(items) when is_list(items), do: :ok

  defp generate_id do
    :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
  end
end


# ── file: lib/billing/invoice_payment.ex ─────────────────────────────────────

defmodule Billing.Invoice do
  @moduledoc """
  Handles payment state transitions for invoices.
  Called by the payment gateway webhook handler after successful charges.
  """

  alias Billing.{AuditLog, Notifier}

  @paid_statuses [:paid]
  @voidable_statuses [:draft, :issued]

  @spec mark_paid(map(), String.t()) :: {:ok, map()} | {:error, String.t()}
  def mark_paid(%{status: status} = invoice, transaction_ref)
      when status in [:draft, :issued] do
    updated =
      invoice
      |> Map.put(:status, :paid)
      |> Map.put(:paid_at, DateTime.utc_now())
      |> Map.put(:transaction_ref, transaction_ref)

    AuditLog.record(:invoice_paid, %{
      invoice_id: invoice.id,
      transaction_ref: transaction_ref,
      amount: invoice.total
    })

    Notifier.send_receipt(invoice.customer_id, updated)

    {:ok, updated}
  end

  def mark_paid(%{status: status}, _ref) when status in @paid_statuses do
    {:error, "invoice is already paid"}
  end

  def mark_paid(_, _), do: {:error, "invoice cannot be marked as paid"}

  @spec void(map(), String.t()) :: {:ok, map()} | {:error, String.t()}
  def void(%{status: status} = invoice, reason)
      when status in @voidable_statuses do
    updated =
      invoice
      |> Map.put(:status, :void)
      |> Map.put(:voided_at, DateTime.utc_now())
      |> Map.put(:void_reason, reason)

    AuditLog.record(:invoice_voided, %{invoice_id: invoice.id, reason: reason})

    {:ok, updated}
  end

  def void(_, _), do: {:error, "invoice cannot be voided in its current state"}

  @spec overdue?(map()) :: boolean()
  def overdue?(%{status: :issued, due_date: due_date}) do
    Date.compare(due_date, Date.utc_today()) == :lt
  end

  def overdue?(_), do: false
end
```
