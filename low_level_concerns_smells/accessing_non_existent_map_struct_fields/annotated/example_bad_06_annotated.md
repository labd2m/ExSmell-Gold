# Annotated Example 06

## Metadata

- **Smell name:** Accessing non-existent Map/Struct fields
- **Expected smell location:** `InvoiceProcessor.apply_discount/2`, lines where `discount` map keys are accessed dynamically
- **Affected function(s):** `apply_discount/2`
- **Short explanation:** The function uses dynamic access (`discount[:type]`, `discount[:value]`, `discount[:cap]`) on a plain map whose keys may or may not be present. When `:cap` is absent the expression silently returns `nil`, which is then fed into a numeric comparison, producing a misleading result instead of a clear error.

---

```elixir
defmodule Billing.InvoiceProcessor do
  @moduledoc """
  Handles invoice creation, line-item aggregation, and discount application
  for the billing subsystem.
  """

  alias Billing.Invoice
  alias Billing.LineItem

  @tax_rate 0.12

  @spec build(list(map()), map()) :: Invoice.t()
  def build(line_items, customer) do
    subtotal =
      line_items
      |> Enum.map(&LineItem.total/1)
      |> Enum.sum()

    tax = Float.round(subtotal * @tax_rate, 2)

    %Invoice{
      customer_id: customer.id,
      customer_name: customer.name,
      line_items: line_items,
      subtotal: subtotal,
      tax: tax,
      total: subtotal + tax,
      issued_at: DateTime.utc_now()
    }
  end

  @spec apply_discount(Invoice.t(), map()) :: Invoice.t()
  def apply_discount(%Invoice{} = invoice, discount) do
    # VALIDATION: SMELL START - Accessing non-existent Map/Struct fields
    # VALIDATION: This is a smell because `discount[:type]`, `discount[:value]`,
    # and `discount[:cap]` use dynamic (bracket) access on a plain map whose
    # keys are not guaranteed to exist. If `:cap` is absent the expression
    # returns `nil`, and `min(discounted_amount, nil)` will raise or silently
    # propagate `nil` through further arithmetic instead of signalling that the
    # discount map was malformed. The same ambiguity applies to `:type` and
    # `:value`: a missing key and an explicitly `nil` value are
    # indistinguishable.
    discount_type  = discount[:type]
    discount_value = discount[:value]
    discount_cap   = discount[:cap]
    # VALIDATION: SMELL END

    discounted_amount =
      case discount_type do
        :percentage ->
          invoice.subtotal * (1 - discount_value / 100)

        :fixed ->
          invoice.subtotal - discount_value

        _ ->
          invoice.subtotal
      end

    capped_amount =
      if discount_cap do
        min(discounted_amount, discount_cap)
      else
        discounted_amount
      end

    tax = Float.round(capped_amount * @tax_rate, 2)

    %Invoice{invoice | subtotal: capped_amount, tax: tax, total: capped_amount + tax}
  end

  @spec finalize(Invoice.t(), String.t()) :: {:ok, Invoice.t()} | {:error, String.t()}
  def finalize(%Invoice{total: total} = invoice, payment_method)
      when is_binary(payment_method) do
    cond do
      total <= 0 ->
        {:error, "Invoice total must be positive, got #{total}"}

      payment_method not in ["credit_card", "bank_transfer", "wallet"] ->
        {:error, "Unsupported payment method: #{payment_method}"}

      true ->
        {:ok, %Invoice{invoice | status: :finalized, payment_method: payment_method}}
    end
  end

  @spec line_item_summary(Invoice.t()) :: list(map())
  def line_item_summary(%Invoice{line_items: items}) do
    Enum.map(items, fn item ->
      %{
        description: item.description,
        quantity: item.quantity,
        unit_price: item.unit_price,
        total: LineItem.total(item)
      }
    end)
  end

  @spec total_with_tax(Invoice.t()) :: float()
  def total_with_tax(%Invoice{subtotal: subtotal}) do
    subtotal + Float.round(subtotal * @tax_rate, 2)
  end
end
```
