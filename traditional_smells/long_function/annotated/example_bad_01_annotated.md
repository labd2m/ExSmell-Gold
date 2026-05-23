# Annotated Example — Long Function

## Metadata

- **Smell name:** Long Function
- **Expected smell location:** `InvoiceProcessor.generate/2`
- **Affected function(s):** `generate/2`
- **Short explanation:** The `generate/2` function handles multiple distinct responsibilities — validating the order, computing line-item totals, applying discounts, calculating taxes, assembling the invoice map, and persisting the result — all within a single monolithic function. Each of these concerns could be extracted into focused helper functions, making the code easier to read, test, and maintain.

---

```elixir
defmodule Billing.InvoiceProcessor do
  @moduledoc """
  Handles generation and persistence of invoices from confirmed orders.
  """

  alias Billing.{Invoice, Repo, TaxRules, DiscountEngine}
  alias Orders.Order
  require Logger

  @tax_rate_default 0.15
  @invoice_prefix "INV"

  # VALIDATION: SMELL START - Long Function
  # VALIDATION: This is a smell because `generate/2` is a single function that
  # VALIDATION: bundles order validation, item computation, discount logic,
  # VALIDATION: tax calculation, invoice assembly, and persistence together.
  # VALIDATION: It far exceeds ten lines and handles too many responsibilities.
  def generate(%Order{} = order, opts \\ []) do
    currency = Keyword.get(opts, :currency, "USD")
    issued_by = Keyword.get(opts, :issued_by, "system")

    # --- Validate order state ---
    if order.status not in [:confirmed, :processing] do
      Logger.warning("Attempted to invoice order #{order.id} with status #{order.status}")
      {:error, :invalid_order_status}
    else
      # --- Compute line items ---
      line_items =
        Enum.map(order.items, fn item ->
          unit_price = item.unit_price
          quantity = item.quantity
          subtotal = unit_price * quantity

          discount_pct =
            cond do
              quantity >= 100 -> 0.10
              quantity >= 50  -> 0.05
              true            -> 0.0
            end

          discount_amount = subtotal * discount_pct
          net = subtotal - discount_amount

          %{
            sku: item.sku,
            description: item.description,
            unit_price: unit_price,
            quantity: quantity,
            subtotal: subtotal,
            discount_pct: discount_pct,
            discount_amount: discount_amount,
            net: net
          }
        end)

      # --- Apply order-level discount ---
      order_subtotal = Enum.reduce(line_items, 0, fn li, acc -> acc + li.net end)

      order_discount =
        case DiscountEngine.lookup(order.customer_id) do
          {:ok, %{rate: rate}} -> order_subtotal * rate
          _                    -> 0.0
        end

      discounted_total = order_subtotal - order_discount

      # --- Calculate tax ---
      tax_rate =
        case TaxRules.rate_for_region(order.shipping_address.country) do
          {:ok, rate} -> rate
          _           -> @tax_rate_default
        end

      tax_amount = discounted_total * tax_rate
      grand_total = discounted_total + tax_amount

      # --- Build invoice number ---
      sequence = :erlang.unique_integer([:positive, :monotonic])
      invoice_number = "#{@invoice_prefix}-#{Date.utc_today() |> Date.to_iso8601()}-#{sequence}"

      # --- Assemble invoice ---
      invoice_attrs = %{
        invoice_number: invoice_number,
        order_id: order.id,
        customer_id: order.customer_id,
        issued_by: issued_by,
        currency: currency,
        line_items: line_items,
        subtotal: order_subtotal,
        order_discount: order_discount,
        tax_rate: tax_rate,
        tax_amount: tax_amount,
        grand_total: grand_total,
        issued_at: DateTime.utc_now(),
        due_at: DateTime.add(DateTime.utc_now(), 30 * 86_400, :second),
        status: :draft
      }

      # --- Persist ---
      case Repo.insert(Invoice.changeset(%Invoice{}, invoice_attrs)) do
        {:ok, invoice} ->
          Logger.info("Invoice #{invoice.invoice_number} created for order #{order.id}")
          {:ok, invoice}

        {:error, changeset} ->
          Logger.error("Failed to persist invoice for order #{order.id}: #{inspect(changeset.errors)}")
          {:error, changeset}
      end
    end
  end
  # VALIDATION: SMELL END

  defp build_line_item_summary(line_items) do
    Enum.map(line_items, &Map.take(&1, [:sku, :description, :net]))
  end
end
```
