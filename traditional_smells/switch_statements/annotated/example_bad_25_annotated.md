# Annotated Example — Switch Statements

## Metadata

- **Smell name:** Switch Statements
- **Expected smell location:** `BillingCalculator.calculate_discount/2` and `BillingCalculator.calculate_late_fee/2`
- **Affected functions:** `calculate_discount/2`, `calculate_late_fee/2`
- **Short explanation:** The same `case` branching over `customer_tier` (`:bronze`, `:silver`, `:gold`, `:platinum`) is duplicated in two separate functions. Adding a new tier (e.g., `:diamond`) requires updating both `case` expressions independently, which is error-prone and violates the DRY principle.

---

```elixir
defmodule BillingCalculator do
  @moduledoc """
  Handles billing calculations for subscription-based customers,
  including discounts, late fees, and invoice totals.
  """

  alias BillingCalculator.{Invoice, Customer}

  @base_late_fee_rate 0.05
  @grace_period_days 7

  @spec compute_invoice_total(Invoice.t(), Customer.t()) :: {:ok, map()} | {:error, String.t()}
  def compute_invoice_total(%Invoice{} = invoice, %Customer{} = customer) do
    with {:ok, subtotal} <- calculate_subtotal(invoice),
         {:ok, discount} <- calculate_discount(subtotal, customer.tier),
         {:ok, tax} <- calculate_tax(subtotal - discount, customer.region),
         {:ok, late_fee} <- maybe_apply_late_fee(invoice, customer) do
      total = subtotal - discount + tax + late_fee

      {:ok,
       %{
         subtotal: subtotal,
         discount: discount,
         tax: tax,
         late_fee: late_fee,
         total: Float.round(total, 2)
       }}
    end
  end

  @spec calculate_subtotal(Invoice.t()) :: {:ok, float()} | {:error, String.t()}
  defp calculate_subtotal(%Invoice{line_items: items}) when is_list(items) do
    total =
      Enum.reduce(items, 0.0, fn %{quantity: qty, unit_price: price}, acc ->
        acc + qty * price
      end)

    {:ok, total}
  end

  defp calculate_subtotal(_), do: {:error, "invalid invoice structure"}

  # VALIDATION: SMELL START - Switch Statements
  # VALIDATION: This is a smell because the same case branching on `customer_tier`
  # also appears in `calculate_late_fee/2` below. Both functions repeat the
  # identical set of tier conditions, so adding a new tier forces changes in two places.
  @spec calculate_discount(float(), atom()) :: {:ok, float()} | {:error, String.t()}
  defp calculate_discount(subtotal, customer_tier) do
    discount_rate =
      case customer_tier do
        :bronze   -> 0.00
        :silver   -> 0.05
        :gold     -> 0.10
        :platinum -> 0.15
        _         -> {:error, "unknown customer tier: #{customer_tier}"}
      end

    case discount_rate do
      {:error, _} = err -> err
      rate -> {:ok, subtotal * rate}
    end
  end
  # VALIDATION: SMELL END

  @spec maybe_apply_late_fee(Invoice.t(), Customer.t()) :: {:ok, float()} | {:error, String.t()}
  defp maybe_apply_late_fee(%Invoice{due_date: due_date, paid_at: nil} = invoice, customer) do
    days_overdue = Date.diff(Date.utc_today(), due_date)

    if days_overdue > @grace_period_days do
      calculate_late_fee(invoice, customer.tier)
    else
      {:ok, 0.0}
    end
  end

  defp maybe_apply_late_fee(%Invoice{paid_at: paid_at}, _customer) when not is_nil(paid_at) do
    {:ok, 0.0}
  end

  # VALIDATION: SMELL START - Switch Statements
  # VALIDATION: This is a smell because the same case branching on `customer_tier`
  # already appeared in `calculate_discount/2` above. The conditions :bronze, :silver,
  # :gold, :platinum are duplicated here, requiring parallel updates on tier changes.
  @spec calculate_late_fee(Invoice.t(), atom()) :: {:ok, float()} | {:error, String.t()}
  defp calculate_late_fee(%Invoice{amount_due: amount_due}, customer_tier) do
    fee_multiplier =
      case customer_tier do
        :bronze   -> 1.0
        :silver   -> 0.80
        :gold     -> 0.60
        :platinum -> 0.40
        _         -> {:error, "unknown customer tier: #{customer_tier}"}
      end

    case fee_multiplier do
      {:error, _} = err -> err
      multiplier -> {:ok, amount_due * @base_late_fee_rate * multiplier}
    end
  end
  # VALIDATION: SMELL END

  @spec calculate_tax(float(), String.t()) :: {:ok, float()} | {:error, String.t()}
  defp calculate_tax(taxable_amount, region) do
    rate =
      case region do
        "US-CA" -> 0.0725
        "US-NY" -> 0.08
        "US-TX" -> 0.0625
        "EU"    -> 0.20
        _       -> 0.0
      end

    {:ok, taxable_amount * rate}
  end
end
```
