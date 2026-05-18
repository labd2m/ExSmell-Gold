# Annotated Example 16 — Unnecessary Macros

## Metadata

- **Smell name:** Unnecessary macros
- **Expected smell location:** `defmacro apply_tax/2` inside `Billing.TaxEngine`
- **Affected function(s):** `apply_tax/2`
- **Short explanation:** The macro multiplies an amount by a tax rate and rounds the result — entirely a runtime arithmetic operation. A regular function is simpler, more testable, and idiomatic Elixir.

---

```elixir
defmodule Billing.TaxEngine do
  @moduledoc """
  Calculates applicable taxes for billing line items based on
  jurisdiction codes and product tax categories.
  """

  @tax_rates %{
    "US-CA" => 0.0725,
    "US-NY" => 0.08,
    "US-TX" => 0.0625,
    "US-WA" => 0.065,
    "EU-DE" => 0.19,
    "EU-FR" => 0.20,
    "EU-ES" => 0.21
  }

  # VALIDATION: SMELL START - Unnecessary macros
  # VALIDATION: This is a smell because apply_tax/2 only performs floating-point
  # multiplication and rounding on runtime values. There is no compile-time
  # computation involved; a plain def function is the appropriate abstraction.
  defmacro apply_tax(amount_cents, rate) do
    quote do
      trunc(Float.round(unquote(amount_cents) * unquote(rate), 0))
    end
  end
  # VALIDATION: SMELL END

  @doc """
  Looks up the tax rate for a given jurisdiction code.
  Returns `{:ok, rate}` or `{:error, :unknown_jurisdiction}`.
  """
  @spec rate_for_jurisdiction(String.t()) :: {:ok, float()} | {:error, :unknown_jurisdiction}
  def rate_for_jurisdiction(jurisdiction_code) do
    case Map.fetch(@tax_rates, jurisdiction_code) do
      {:ok, rate} -> {:ok, rate}
      :error -> {:error, :unknown_jurisdiction}
    end
  end

  @doc """
  Returns whether a product category is tax-exempt in the given jurisdiction.
  """
  @spec exempt?(String.t(), atom()) :: boolean()
  def exempt?("US-" <> _, :groceries), do: true
  def exempt?("US-" <> _, :prescription_drugs), do: true
  def exempt?(_jurisdiction, _category), do: false
end

defmodule Billing.LineItemCalculator do
  @moduledoc """
  Calculates per-line-item totals including applicable taxes for invoices.
  Used during checkout and when generating proforma invoices.
  """

  require Billing.TaxEngine

  alias Billing.TaxEngine

  @doc """
  Computes a fully broken-down total for a single line item.
  Returns a map with the subtotal, tax, and grand total in cents.
  """
  @spec calculate(map(), String.t()) :: {:ok, map()} | {:error, atom()}
  def calculate(%{sku: sku, unit_price_cents: unit_price, quantity: qty, category: category}, jurisdiction) do
    subtotal = unit_price * qty

    if TaxEngine.exempt?(jurisdiction, category) do
      {:ok,
       %{
         sku: sku,
         quantity: qty,
         subtotal_cents: subtotal,
         tax_cents: 0,
         total_cents: subtotal,
         tax_rate: 0.0,
         jurisdiction: jurisdiction
       }}
    else
      case TaxEngine.rate_for_jurisdiction(jurisdiction) do
        {:ok, rate} ->
          tax = TaxEngine.apply_tax(subtotal, rate)

          {:ok,
           %{
             sku: sku,
             quantity: qty,
             subtotal_cents: subtotal,
             tax_cents: tax,
             total_cents: subtotal + tax,
             tax_rate: rate,
             jurisdiction: jurisdiction
           }}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @doc """
  Computes totals for all line items in an order, stopping on the first error.
  """
  @spec calculate_all(list(map()), String.t()) :: {:ok, list(map())} | {:error, atom()}
  def calculate_all(line_items, jurisdiction) do
    Enum.reduce_while(line_items, {:ok, []}, fn item, {:ok, acc} ->
      case calculate(item, jurisdiction) do
        {:ok, result} -> {:cont, {:ok, [result | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, results} -> {:ok, Enum.reverse(results)}
      error -> error
    end
  end

  @doc """
  Aggregates computed line item results into an order-level summary.
  """
  @spec order_summary(list(map())) :: map()
  def order_summary(line_items) do
    %{
      line_count: length(line_items),
      subtotal_cents: Enum.sum(Enum.map(line_items, & &1.subtotal_cents)),
      tax_cents: Enum.sum(Enum.map(line_items, & &1.tax_cents)),
      total_cents: Enum.sum(Enum.map(line_items, & &1.total_cents))
    }
  end
end
```
