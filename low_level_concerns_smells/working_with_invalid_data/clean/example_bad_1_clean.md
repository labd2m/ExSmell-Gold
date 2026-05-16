```elixir
defmodule MyApp.Billing.InvoiceCalculator do
  @moduledoc """
  Handles invoice total calculation including line-item discounts,
  tax application, and currency rounding for the billing subsystem.
  """

  require Logger

  @default_tax_rate 0.15
  @rounding_precision 2

  @type line_item :: %{
          sku: String.t(),
          description: String.t(),
          unit_price: number(),
          quantity: number(),
          discount_percent: number()
        }

  @type invoice :: %{
          invoice_id: String.t(),
          customer_id: String.t(),
          line_items: [line_item()],
          tax_rate: number() | nil,
          notes: String.t()
        }

  @spec calculate_total(invoice()) :: {:ok, map()} | {:error, String.t()}
  def calculate_total(invoice) do
    tax_rate = Map.get(invoice, :tax_rate) || @default_tax_rate

    subtotal =
      invoice.line_items
      |> Enum.map(&calculate_line_total/1)
      |> Enum.sum()

    tax_amount = Float.round(subtotal * tax_rate, @rounding_precision)
    total = Float.round(subtotal + tax_amount, @rounding_precision)

    {:ok,
     %{
       invoice_id: invoice.invoice_id,
       subtotal: subtotal,
       tax_rate: tax_rate,
       tax_amount: tax_amount,
       total: total,
       line_count: length(invoice.line_items)
     }}
  rescue
    e ->
      Logger.error("Invoice calculation failed: #{inspect(e)}")
      {:error, "Calculation failed: #{Exception.message(e)}"}
  end

  @spec apply_line_discount(number(), number()) :: number()
  def apply_line_discount(line_total, discount_percent) do
    discount_amount = line_total * (discount_percent / 100)
    Float.round(line_total - discount_amount, @rounding_precision)
  end

  @spec summarize_by_sku([line_item()]) :: map()
  def summarize_by_sku(line_items) do
    Enum.reduce(line_items, %{}, fn item, acc ->
      current = Map.get(acc, item.sku, 0)
      Map.put(acc, item.sku, current + item.quantity)
    end)
  end

  @spec format_invoice_summary(map()) :: String.t()
  def format_invoice_summary(result) do
    """
    Invoice: #{result.invoice_id}
    Subtotal: $#{result.subtotal}
    Tax (#{result.tax_rate * 100}%): $#{result.tax_amount}
    Total: $#{result.total}
    Line Items: #{result.line_count}
    """
  end

  # Private helpers

  defp calculate_line_total(%{unit_price: unit_price, quantity: quantity, discount_percent: dp}) do
    raw_total = unit_price * quantity
    apply_line_discount(raw_total, dp)
  end

  defp calculate_line_total(%{unit_price: unit_price, quantity: quantity}) do
    unit_price * quantity
  end
end
```
