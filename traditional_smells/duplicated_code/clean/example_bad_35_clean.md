```elixir
defmodule BillingEngine do
  @moduledoc """
  Handles invoice computation and preview generation for subscription billing.
  """

  alias BillingEngine.{LineItem, Customer, Invoice}

  @standard_vat_eu 0.20
  @reduced_vat_eu  0.10
  @vat_uk          0.20
  @sales_tax_us    0.08

  @doc """
  Computes a finalised invoice for the given customer and list of line items.
  Returns `{:ok, Invoice.t()}` or `{:error, reason}`.
  """
  def compute_invoice_total(%Customer{} = customer, line_items) when is_list(line_items) do
    with {:ok, subtotal} <- sum_line_items(line_items),
         {:ok, discount} <- resolve_discount(customer, subtotal),
         discounted      =  subtotal - discount,
         {:ok, _}        <- validate_minimum_charge(discounted) do

      tax =
        cond do
          customer.country in ["DE", "FR", "IT", "ES", "NL", "BE", "PL"] ->
            if customer.vat_exempt?, do: 0.0, else: discounted * @standard_vat_eu

          customer.country in ["IE", "LU"] ->
            if customer.vat_exempt?, do: 0.0, else: discounted * @reduced_vat_eu

          customer.country == "GB" ->
            if customer.vat_exempt?, do: 0.0, else: discounted * @vat_uk

          customer.country == "US" ->
            if customer.tax_exempt?, do: 0.0, else: discounted * @sales_tax_us

          true ->
            0.0
        end

      total = discounted + tax

      invoice = %Invoice{
        customer_id:  customer.id,
        line_items:   line_items,
        subtotal:     subtotal,
        discount:     discount,
        tax:          Float.round(tax, 2),
        total:        Float.round(total, 2),
        currency:     customer.billing_currency,
        issued_at:    DateTime.utc_now(),
        status:       :finalised
      }

      {:ok, invoice}
    end
  end

  @doc """
  Generates a non-binding preview invoice so the customer can confirm
  charges before the billing cycle closes.
  """
  def preview_invoice(%Customer{} = customer, line_items) when is_list(line_items) do
    with {:ok, subtotal} <- sum_line_items(line_items),
         {:ok, discount} <- resolve_discount(customer, subtotal) do

      discounted = subtotal - discount

      tax =
        cond do
          customer.country in ["DE", "FR", "IT", "ES", "NL", "BE", "PL"] ->
            if customer.vat_exempt?, do: 0.0, else: discounted * @standard_vat_eu

          customer.country in ["IE", "LU"] ->
            if customer.vat_exempt?, do: 0.0, else: discounted * @reduced_vat_eu

          customer.country == "GB" ->
            if customer.vat_exempt?, do: 0.0, else: discounted * @vat_uk

          customer.country == "US" ->
            if customer.tax_exempt?, do: 0.0, else: discounted * @sales_tax_us

          true ->
            0.0
        end

      preview = %Invoice{
        customer_id:  customer.id,
        line_items:   line_items,
        subtotal:     subtotal,
        discount:     discount,
        tax:          Float.round(tax, 2),
        total:        Float.round(discounted + tax, 2),
        currency:     customer.billing_currency,
        issued_at:    DateTime.utc_now(),
        status:       :preview
      }

      {:ok, preview}
    end
  end


  defp sum_line_items([]), do: {:error, :empty_line_items}
  defp sum_line_items(items) do
    total =
      Enum.reduce(items, 0.0, fn %LineItem{unit_price: p, quantity: q}, acc ->
        acc + p * q
      end)

    {:ok, Float.round(total, 2)}
  end

  defp resolve_discount(%Customer{discount_pct: nil}, _subtotal), do: {:ok, 0.0}
  defp resolve_discount(%Customer{discount_pct: pct}, subtotal) when pct > 0 do
    {:ok, Float.round(subtotal * (pct / 100.0), 2)}
  end
  defp resolve_discount(_, _), do: {:ok, 0.0}

  defp validate_minimum_charge(amount) when amount >= 0.50, do: {:ok, amount}
  defp validate_minimum_charge(_), do: {:error, :below_minimum_charge}
end
```
