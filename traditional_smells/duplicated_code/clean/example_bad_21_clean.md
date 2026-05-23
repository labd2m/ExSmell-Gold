```elixir
defmodule BillingService do
  @moduledoc """
  Handles invoice generation and billing previews for enterprise customers.
  """

  alias BillingService.{Invoice, LineItem, Customer, TaxRegistry}

  @default_currency "USD"
  @vat_exempt_categories [:hardware_donation, :educational, :non_profit]

  def generate_invoice(customer_id, order_items) do
    with {:ok, customer} <- Customer.fetch(customer_id),
         {:ok, tax_rate} <- TaxRegistry.rate_for(customer.country_code),
         {:ok, items} <- build_line_items(order_items) do

      subtotal =
        Enum.reduce(items, Decimal.new("0.00"), fn item, acc ->
          line_total = Decimal.mult(item.unit_price, Decimal.new(item.quantity))
          Decimal.add(acc, line_total)
        end)

      taxable_subtotal =
        Enum.reduce(items, Decimal.new("0.00"), fn item, acc ->
          if item.category in @vat_exempt_categories do
            acc
          else
            line_total = Decimal.mult(item.unit_price, Decimal.new(item.quantity))
            Decimal.add(acc, line_total)
          end
        end)

      tax_amount = Decimal.mult(taxable_subtotal, Decimal.from_float(tax_rate))
      total = Decimal.add(subtotal, tax_amount) |> Decimal.round(2)

      invoice = %Invoice{
        customer_id: customer.id,
        customer_name: customer.legal_name,
        currency: customer.preferred_currency || @default_currency,
        line_items: items,
        subtotal: subtotal,
        tax_rate: tax_rate,
        tax_amount: Decimal.round(tax_amount, 2),
        total: total,
        issued_at: DateTime.utc_now(),
        due_at: DateTime.add(DateTime.utc_now(), 30 * 86_400, :second),
        status: :pending
      }

      Invoice.persist(invoice)
    end
  end

  def calculate_preview(customer_id, order_items) do
    with {:ok, customer} <- Customer.fetch(customer_id),
         {:ok, tax_rate} <- TaxRegistry.rate_for(customer.country_code),
         {:ok, items} <- build_line_items(order_items) do

      subtotal =
        Enum.reduce(items, Decimal.new("0.00"), fn item, acc ->
          line_total = Decimal.mult(item.unit_price, Decimal.new(item.quantity))
          Decimal.add(acc, line_total)
        end)

      taxable_subtotal =
        Enum.reduce(items, Decimal.new("0.00"), fn item, acc ->
          if item.category in @vat_exempt_categories do
            acc
          else
            line_total = Decimal.mult(item.unit_price, Decimal.new(item.quantity))
            Decimal.add(acc, line_total)
          end
        end)

      tax_amount = Decimal.mult(taxable_subtotal, Decimal.from_float(tax_rate))
      total = Decimal.add(subtotal, tax_amount) |> Decimal.round(2)

      {:ok,
       %{
         currency: customer.preferred_currency || @default_currency,
         line_items: items,
         subtotal: subtotal,
         tax_rate: tax_rate,
         tax_amount: Decimal.round(tax_amount, 2),
         total: total
       }}
    end
  end

  defp build_line_items(order_items) do
    items =
      Enum.map(order_items, fn raw ->
        %LineItem{
          sku: raw.sku,
          description: raw.description,
          unit_price: Decimal.new(to_string(raw.unit_price)),
          quantity: raw.quantity,
          category: Map.get(raw, :category, :standard)
        }
      end)

    {:ok, items}
  end
end
```
