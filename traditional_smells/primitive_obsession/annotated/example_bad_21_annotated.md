# Annotated Example — Primitive Obsession

| Field | Value |
|---|---|
| **Smell name** | Primitive Obsession |
| **Expected smell location** | `InvoiceService` module — function parameters and internal variables throughout |
| **Affected functions** | `create_invoice/3`, `apply_discount/2`, `calculate_tax/2`, `finalize_invoice/1` |
| **Short explanation** | Monetary amounts (`subtotal`, `discount_amount`, `tax_amount`, `total`) are represented as plain `float` values instead of a dedicated `Money` struct or type. This loses currency information, makes arithmetic error-prone (float precision), and forces callers to know the implicit currency convention. |

```elixir
defmodule Billing.InvoiceService do
  @moduledoc """
  Handles invoice creation, discount application, tax calculation,
  and finalization for B2B customers.
  """

  require Logger

  alias Billing.Repo
  alias Billing.Schema.{Invoice, InvoiceLineItem, Customer}

  @default_tax_rate 0.15
  @max_discount_rate 0.30

  # VALIDATION: SMELL START - Primitive Obsession
  # VALIDATION: This is a smell because monetary values (subtotal, discount_amount,
  # tax_amount, total) are passed and returned as plain `float` values instead of
  # a dedicated Money struct (e.g., %Money{amount: integer, currency: :BRL}).
  # This loses currency context and introduces floating-point precision risks.

  @spec create_invoice(Customer.t(), list(map()), float()) ::
          {:ok, Invoice.t()} | {:error, term()}
  def create_invoice(%Customer{} = customer, line_items, discount_rate)
      when is_float(discount_rate) do
    with :ok <- validate_discount_rate(discount_rate),
         {:ok, items} <- build_line_items(line_items),
         subtotal <- compute_subtotal(items),
         discount_amount <- subtotal * discount_rate,
         taxable_amount <- subtotal - discount_amount,
         tax_amount <- calculate_tax(taxable_amount, customer.tax_exempt),
         total <- taxable_amount + tax_amount,
         {:ok, invoice} <-
           persist_invoice(customer, items, subtotal, discount_amount, tax_amount, total) do
      Logger.info("Invoice created for customer=#{customer.id} total=#{total}")
      {:ok, invoice}
    end
  end

  @spec apply_discount(float(), float()) :: float()
  def apply_discount(subtotal, discount_rate)
      when is_float(subtotal) and is_float(discount_rate) do
    discounted = subtotal * (1.0 - discount_rate)
    Float.round(discounted, 2)
  end

  @spec calculate_tax(float(), boolean()) :: float()
  def calculate_tax(taxable_amount, tax_exempt) when is_float(taxable_amount) do
    if tax_exempt do
      0.0
    else
      Float.round(taxable_amount * @default_tax_rate, 2)
    end
  end

  @spec finalize_invoice(Invoice.t()) :: {:ok, map()} | {:error, term()}
  def finalize_invoice(%Invoice{} = invoice) do
    summary = %{
      invoice_id: invoice.id,
      customer_id: invoice.customer_id,
      subtotal: invoice.subtotal,
      discount: invoice.discount_amount,
      tax: invoice.tax_amount,
      total: invoice.total,
      issued_at: DateTime.utc_now()
    }

    case Repo.update(Invoice.changeset(invoice, %{status: :finalized, finalized_at: DateTime.utc_now()})) do
      {:ok, _updated} ->
        Logger.info("Invoice #{invoice.id} finalized. Total due: #{invoice.total}")
        {:ok, summary}

      {:error, changeset} ->
        Logger.error("Failed to finalize invoice #{invoice.id}: #{inspect(changeset.errors)}")
        {:error, :finalization_failed}
    end
  end

  # VALIDATION: SMELL END

  ## Private helpers

  defp validate_discount_rate(rate) when rate < 0.0 or rate > @max_discount_rate do
    {:error, {:invalid_discount_rate, rate}}
  end

  defp validate_discount_rate(_rate), do: :ok

  defp build_line_items(raw_items) do
    items =
      Enum.map(raw_items, fn item ->
        %InvoiceLineItem{
          description: item["description"],
          quantity: item["quantity"],
          unit_price: item["unit_price"] / 1.0,
          line_total: item["quantity"] * item["unit_price"] / 1.0
        }
      end)

    {:ok, items}
  end

  defp compute_subtotal(items) do
    items
    |> Enum.map(& &1.line_total)
    |> Enum.sum()
    |> Float.round(2)
  end

  defp persist_invoice(customer, items, subtotal, discount_amount, tax_amount, total) do
    attrs = %{
      customer_id: customer.id,
      subtotal: subtotal,
      discount_amount: discount_amount,
      tax_amount: tax_amount,
      total: total,
      status: :draft,
      issued_at: DateTime.utc_now()
    }

    invoice = Invoice.changeset(%Invoice{line_items: items}, attrs)
    Repo.insert(invoice)
  end
end
```
