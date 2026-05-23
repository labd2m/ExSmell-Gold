# Annotated Example: Primitive Obsession

## Metadata

- **Smell Name**: Primitive Obsession
- **Expected Smell Location**: `apply_discount/3`, `calculate_tax/3`, `sum_line_items/1`, `compare_amounts/4`, `format_amount/2`
- **Affected Function(s)**: All public functions in `Billing.InvoiceCalculator`
- **Explanation**: `amount` and `currency` are passed as raw `float` and `String.t()` primitives throughout the module instead of being encapsulated in a dedicated `%Money{}` struct. This forces callers to always carry two values together, makes currency-safety checks manual and error-prone, and scatters rounding logic across multiple functions.

## Code

```elixir
defmodule Billing.InvoiceCalculator do
  @moduledoc """
  Handles invoice line-item calculations, tax application, and discount
  processing for the billing subsystem.
  """

  require Logger

  @tax_rates %{
    "US-CA" => 0.0725,
    "US-NY" => 0.08875,
    "US-TX" => 0.0625,
    "US-WA" => 0.0650,
    "BR-SP" => 0.12,
    "DEFAULT" => 0.07
  }

  @max_single_discount 0.30

  # VALIDATION: SMELL START - Primitive Obsession
  # VALIDATION: This is a smell because `amount` and `currency` are modelled as a
  # VALIDATION: raw `float` and a plain `String.t()` instead of a single `%Money{}`
  # VALIDATION: struct. A Money struct would encapsulate currency-aware arithmetic,
  # VALIDATION: rounding rules, and prevent callers from accidentally mixing
  # VALIDATION: incompatible currencies across function boundaries.
  @spec apply_discount(float(), String.t(), float()) ::
          {:ok, float(), String.t()} | {:error, String.t()}
  def apply_discount(amount, currency, discount_rate)
      when is_float(amount) and is_binary(currency) and is_float(discount_rate) do
    if discount_rate < 0.0 or discount_rate > @max_single_discount do
      {:error,
       "Discount rate #{discount_rate} is outside the allowed range " <>
         "[0.0, #{@max_single_discount}]"}
    else
      discounted = Float.round(amount * (1.0 - discount_rate), 2)
      {:ok, discounted, currency}
    end
  end

  @spec calculate_tax(float(), String.t(), String.t()) ::
          {:ok, float(), float()} | {:error, String.t()}
  def calculate_tax(amount, currency, region)
      when is_float(amount) and is_binary(currency) and is_binary(region) do
    rate = Map.get(@tax_rates, region, @tax_rates["DEFAULT"])
    tax = Float.round(amount * rate, 2)
    total = Float.round(amount + tax, 2)

    Logger.debug(
      "Tax calculation: #{amount} #{currency} + #{tax} #{currency} tax = #{total} #{currency}"
    )

    {:ok, tax, total}
  end

  @spec sum_line_items(list(map())) ::
          {:ok, float(), String.t()} | {:error, String.t()}
  def sum_line_items([]), do: {:error, "Cannot sum empty line items"}

  def sum_line_items(line_items) do
    currencies = line_items |> Enum.map(& &1.currency) |> Enum.uniq()

    if length(currencies) > 1 do
      {:error, "Mixed currencies in line items: #{Enum.join(currencies, ", ")}"}
    else
      [currency] = currencies

      total =
        line_items
        |> Enum.map(&Float.round(&1.unit_price * &1.quantity, 2))
        |> Enum.sum()
        |> Float.round(2)

      {:ok, total, currency}
    end
  end

  @spec build_invoice(String.t(), list(map()), float(), String.t()) ::
          {:ok, map()} | {:error, String.t()}
  def build_invoice(customer_id, line_items, discount_rate, region) do
    with {:ok, subtotal, currency} <- sum_line_items(line_items),
         {:ok, discounted_subtotal, ^currency} <-
           apply_discount(subtotal, currency, discount_rate),
         {:ok, tax_amount, total} <- calculate_tax(discounted_subtotal, currency, region) do
      invoice = %{
        id: generate_invoice_id(),
        customer_id: customer_id,
        line_items: line_items,
        subtotal: subtotal,
        currency: currency,
        discount_rate: discount_rate,
        discounted_subtotal: discounted_subtotal,
        tax_amount: tax_amount,
        total: total,
        region: region,
        created_at: DateTime.utc_now()
      }

      Logger.info(
        "Invoice #{invoice.id} created for customer #{customer_id}: #{total} #{currency}"
      )

      {:ok, invoice}
    else
      {:error, reason} ->
        Logger.error("Failed to build invoice for customer #{customer_id}: #{reason}")
        {:error, reason}
    end
  end

  @spec format_amount(float(), String.t()) :: String.t()
  def format_amount(amount, currency) when is_float(amount) and is_binary(currency) do
    symbol = currency_symbol(currency)
    "#{symbol}#{:erlang.float_to_binary(amount, decimals: 2)}"
  end

  @spec compare_amounts(float(), String.t(), float(), String.t()) ::
          {:ok, :greater | :lesser | :equal} | {:error, String.t()}
  def compare_amounts(amount_a, currency_a, amount_b, currency_b) do
    if currency_a != currency_b do
      {:error,
       "Cannot compare amounts in different currencies: #{currency_a} vs #{currency_b}"}
    else
      result =
        cond do
          amount_a > amount_b -> :greater
          amount_a < amount_b -> :lesser
          true -> :equal
        end

      {:ok, result}
    end
  end
  # VALIDATION: SMELL END

  defp currency_symbol("USD"), do: "$"
  defp currency_symbol("EUR"), do: "€"
  defp currency_symbol("GBP"), do: "£"
  defp currency_symbol("BRL"), do: "R$"
  defp currency_symbol(other), do: "#{other} "

  defp generate_invoice_id do
    :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
  end
end
```
