# Annotated Example — Speculative Generality

## Metadata

- **Smell name:** Speculative Generality
- **Expected smell location:** `apply_volume_discount/1`
- **Affected function(s):** `apply_volume_discount/1`
- **Short explanation:** The function destructures `invoice_type` from the invoice struct and feeds it into a `case` expression, but the `case` contains only a wildcard (`_`) clause. The intent was to support different volume-discount rates per invoice type in the future, but that flexibility was never implemented — the system always applies the same 5% rate regardless of type.

---

```elixir
defmodule Billing.DiscountEngine do
  @moduledoc """
  Handles multi-stage discount calculations for customer invoices.

  Discounts are applied in the following order:
    1. Contract discount (negotiated per-customer rate)
    2. Loyalty discount (for long-standing customers)
    3. Volume discount (for invoices with many line items)

  All monetary values are stored as floats representing USD amounts.
  """

  alias Billing.{Invoice, Customer, Contract}

  @base_loyalty_discount 0.10
  @loyalty_threshold_months 12
  @volume_line_item_threshold 10

  @spec process_invoice_discounts(Invoice.t()) :: Invoice.t()
  def process_invoice_discounts(%Invoice{} = invoice) do
    invoice
    |> apply_contract_discount()
    |> apply_loyalty_discount()
    |> apply_volume_discount()
    |> finalize_discounts()
  end

  defp apply_contract_discount(%Invoice{customer_id: customer_id} = invoice) do
    case fetch_active_contract(customer_id) do
      {:ok, %Contract{discount_rate: rate}} when rate > 0 ->
        discounted = Float.round(invoice.subtotal * (1 - rate), 2)

        %{invoice
          | subtotal: discounted,
            applied_discounts: [:contract | invoice.applied_discounts]}

      {:ok, _contract} ->
        invoice

      {:error, :not_found} ->
        invoice
    end
  end

  defp apply_loyalty_discount(%Invoice{customer_id: customer_id} = invoice) do
    case fetch_customer(customer_id) do
      {:ok, %Customer{months_active: months}} when months >= @loyalty_threshold_months ->
        discounted = Float.round(invoice.subtotal * (1 - @base_loyalty_discount), 2)

        %{invoice
          | subtotal: discounted,
            applied_discounts: [:loyalty | invoice.applied_discounts]}

      {:ok, _customer} ->
        invoice

      {:error, _reason} ->
        invoice
    end
  end

  # VALIDATION: SMELL START - Speculative Generality
  # VALIDATION: This is a smell because `invoice_type` is extracted from the struct 
  # and used as the subject of a `case` expression, but the only clause is a wildcard 
  # (`_`). The developer anticipated needing different discount rates for different 
  # invoice types (e.g., :standard, :recurring, :proforma), but the system always 
  # applies 5% regardless. The extraction and case are dead speculative structure.
  defp apply_volume_discount(%{invoice_type: invoice_type} = invoice) do
    rate =
      case invoice_type do
        _ -> 0.05
      end

    if invoice.line_item_count >= @volume_line_item_threshold do
      discounted = Float.round(invoice.subtotal * (1 - rate), 2)

      %{invoice
        | subtotal: discounted,
          applied_discounts: [:volume | invoice.applied_discounts]}
    else
      invoice
    end
  end
  # VALIDATION: SMELL END

  defp finalize_discounts(%Invoice{subtotal: subtotal} = invoice) do
    %{invoice
      | subtotal: Float.round(subtotal, 2),
        discount_finalized_at: DateTime.utc_now(),
        discount_count: length(invoice.applied_discounts)}
  end

  defp fetch_active_contract(customer_id) do
    case :ets.lookup(:contracts_cache, customer_id) do
      [{^customer_id, contract}] -> {:ok, contract}
      [] -> {:error, :not_found}
    end
  end

  defp fetch_customer(customer_id) do
    case :ets.lookup(:customers_cache, customer_id) do
      [{^customer_id, customer}] -> {:ok, customer}
      [] -> {:error, :not_found}
    end
  end
end
```
