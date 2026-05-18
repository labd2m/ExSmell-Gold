```elixir
defmodule Billing.TaxCalculator do
  @moduledoc """
  Computes applicable taxes for orders based on jurisdiction rules,
  product tax categories, and customer exemption status.
  Used by the checkout pipeline and invoice generation service.
  """

  @default_precision 2

  @tax_rates %{
    "BR-SP" => 0.18,
    "BR-RJ" => 0.17,
    "US-CA" => 0.0725,
    "US-NY" => 0.08,
    "DE"    => 0.19,
    "FR"    => 0.20,
    "GB"    => 0.20
  }


  def rate_for(jurisdiction, product_category \\ :standard) do
    base = Map.get(@tax_rates, jurisdiction, 0.0)

    case product_category do
      :food        -> base * 0.5
      :medicine    -> 0.0
      :luxury      -> base * 1.25
      :standard    -> base
      _            -> base
    end
  end

  def apply(order) do
    require Billing.TaxCalculator

    jurisdiction = "#{order.country}-#{order.state}"
    rate = rate_for(jurisdiction, order.product_category)

    tax_amount = Billing.TaxCalculator.compute_tax(order.subtotal, rate)

    %{
      order_id:      order.id,
      subtotal:      order.subtotal,
      tax_rate:      rate,
      tax_amount:    tax_amount,
      total:         Float.round(order.subtotal + tax_amount, @default_precision),
      jurisdiction:  jurisdiction
    }
  end

  def apply_batch(orders) do
    Enum.map(orders, &apply/1)
  end

  def breakdown(line_items, jurisdiction) do
    require Billing.TaxCalculator

    Enum.map(line_items, fn item ->
      rate   = rate_for(jurisdiction, item.category)
      tax    = Billing.TaxCalculator.compute_tax(item.unit_price * item.quantity, rate)

      %{
        sku:       item.sku,
        quantity:  item.quantity,
        subtotal:  item.unit_price * item.quantity,
        tax_rate:  rate,
        tax:       tax
      }
    end)
  end

  def total_tax(line_items, jurisdiction) do
    breakdown(line_items, jurisdiction)
    |> Enum.reduce(0.0, fn row, acc -> acc + row.tax end)
    |> Float.round(@default_precision)
  end

  def exempt?(customer) do
    customer.tax_exempt == true and not is_nil(customer.exemption_certificate)
  end

  def effective_rate(order) do
    if exempt?(order.customer) do
      0.0
    else
      rate_for("#{order.country}-#{order.state}", order.product_category)
    end
  end
end
```
