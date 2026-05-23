# Example Bad 01 — Annotated

## Metadata

- **Smell Name**: Shotgun Surgery
- **Expected Smell Location**: Functions `calculate_invoice/2`, `apply_tax/2`, `generate_receipt_label/1`, and `get_billing_cycle/1` inside `Billing.InvoiceProcessor`
- **Affected Functions**: `calculate_invoice/2`, `apply_tax/2`, `generate_receipt_label/1`, `get_billing_cycle/1`
- **Explanation**: The subscription plan logic (`:basic`, `:professional`, `:enterprise`) is spread across four separate functions. Adding a new plan type (e.g., `:enterprise_plus`) requires four small, independent changes scattered throughout the module — each easy to overlook individually, and together representing a single logical concern fragmented across many locations.

```elixir
defmodule Billing.InvoiceProcessor do
  @moduledoc """
  Handles invoice generation, tax calculation, receipt labeling,
  and billing cycle scheduling for subscription-based customers.
  """

  alias Billing.{Invoice, TaxEngine, ReceiptStore, Mailer}

  @default_tax_rate 0.18

  def process_invoice(%Invoice{} = invoice, subscription) do
    invoice
    |> calculate_invoice(subscription)
    |> apply_tax(subscription)
    |> attach_receipt_label(subscription)
    |> schedule_next_billing(subscription)
    |> persist_invoice()
  end

  def persist_invoice(%Invoice{} = invoice) do
    case ReceiptStore.insert(invoice) do
      {:ok, saved} ->
        Mailer.send_invoice_email(saved)
        {:ok, saved}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # VALIDATION: SMELL START - Shotgun Surgery [location 1 of 4]
  # VALIDATION: This is a smell because adding a new plan type (e.g., :enterprise_plus)
  # requires a new clause here AND in apply_tax/2, generate_receipt_label/1,
  # and get_billing_cycle/1 — four scattered changes for one logical addition.
  def calculate_invoice(%Invoice{} = invoice, %{plan: :basic}) do
    %{invoice |
      amount: invoice.base_amount * 1.0,
      line_items: build_line_items(:basic)
    }
  end

  def calculate_invoice(%Invoice{} = invoice, %{plan: :professional}) do
    %{invoice |
      amount: invoice.base_amount * 0.90,
      line_items: build_line_items(:professional)
    }
  end

  def calculate_invoice(%Invoice{} = invoice, %{plan: :enterprise}) do
    %{invoice |
      amount: invoice.base_amount * 0.75,
      line_items: build_line_items(:enterprise)
    }
  end

  def calculate_invoice(%Invoice{} = invoice, _subscription) do
    %{invoice |
      amount: invoice.base_amount,
      line_items: build_line_items(:default)
    }
  end
  # VALIDATION: SMELL END [location 1 of 4]

  # VALIDATION: SMELL START - Shotgun Surgery [location 2 of 4]
  # VALIDATION: This is a smell because a new plan requires an additional tax clause here
  # in addition to the change already needed in calculate_invoice/2.
  def apply_tax(%Invoice{} = invoice, %{plan: :basic}) do
    tax = TaxEngine.compute(invoice.amount, rate: 0.18)
    %{invoice | tax: tax, total: invoice.amount + tax}
  end

  def apply_tax(%Invoice{} = invoice, %{plan: :professional}) do
    tax = TaxEngine.compute(invoice.amount, rate: 0.15)
    %{invoice | tax: tax, total: invoice.amount + tax}
  end

  def apply_tax(%Invoice{} = invoice, %{plan: :enterprise}) do
    tax = TaxEngine.compute(invoice.amount, rate: 0.12)
    %{invoice | tax: tax, total: invoice.amount + tax}
  end

  def apply_tax(%Invoice{} = invoice, _subscription) do
    tax = TaxEngine.compute(invoice.amount, rate: @default_tax_rate)
    %{invoice | tax: tax, total: invoice.amount + tax}
  end
  # VALIDATION: SMELL END [location 2 of 4]

  def attach_receipt_label(%Invoice{} = invoice, subscription) do
    label = generate_receipt_label(subscription)
    %{invoice | label: label}
  end

  # VALIDATION: SMELL START - Shotgun Surgery [location 3 of 4]
  # VALIDATION: This is a smell because a new plan requires a new label clause here,
  # independent of the changes needed in calculate_invoice/2 and apply_tax/2.
  defp generate_receipt_label(%{plan: :basic}),        do: "BASIC-INV"
  defp generate_receipt_label(%{plan: :professional}), do: "PRO-INV"
  defp generate_receipt_label(%{plan: :enterprise}),   do: "ENT-INV"
  defp generate_receipt_label(_),                      do: "STD-INV"
  # VALIDATION: SMELL END [location 3 of 4]

  def schedule_next_billing(%Invoice{} = invoice, subscription) do
    cycle_days = get_billing_cycle(subscription)
    next_date  = Date.add(invoice.issued_at, cycle_days)
    %{invoice | next_billing_date: next_date}
  end

  # VALIDATION: SMELL START - Shotgun Surgery [location 4 of 4]
  # VALIDATION: This is a smell because a new plan also requires a new clause here,
  # completing the four-location change required for every single new plan type.
  defp get_billing_cycle(%{plan: :basic}),        do: 30
  defp get_billing_cycle(%{plan: :professional}), do: 30
  defp get_billing_cycle(%{plan: :enterprise}),   do: 90
  defp get_billing_cycle(_),                      do: 30
  # VALIDATION: SMELL END [location 4 of 4]

  defp build_line_items(:basic) do
    [%{description: "Basic Subscription", qty: 1, unit_price: 29.00}]
  end

  defp build_line_items(:professional) do
    [
      %{description: "Professional Subscription", qty: 1, unit_price: 79.00},
      %{description: "Priority Support Add-on",   qty: 1, unit_price: 10.00}
    ]
  end

  defp build_line_items(:enterprise) do
    [
      %{description: "Enterprise Subscription",  qty: 1, unit_price: 199.00},
      %{description: "Dedicated Support",        qty: 1, unit_price: 0.00},
      %{description: "SLA Guarantee",            qty: 1, unit_price: 0.00}
    ]
  end

  defp build_line_items(_) do
    [%{description: "Standard Subscription", qty: 1, unit_price: 9.00}]
  end
end
```
