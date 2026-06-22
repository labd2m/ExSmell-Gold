```elixir
defmodule Catalog.Products.PricingPolicy do
  @moduledoc """
  Defines protocol-based pricing policy evaluation for catalog products.

  Allows diverse product types (digital, physical, subscription) to implement
  their own pricing rules while sharing a common calculation interface.
  """

  alias Catalog.Products.{DigitalProduct, PhysicalProduct, Subscription}
  alias Catalog.Pricing.{Discount, TaxRate}

  defprotocol Priceable do
    @doc "Returns the base price for a product before discounts and taxes."
    @spec base_price(t()) :: Decimal.t()
    def base_price(product)

    @doc "Returns the applicable tax category identifier."
    @spec tax_category(t()) :: atom()
    def tax_category(product)
  end

  defimpl Priceable, for: DigitalProduct do
    def base_price(%DigitalProduct{price: price}), do: price
    def tax_category(%DigitalProduct{region: :eu}), do: :digital_services_eu
    def tax_category(%DigitalProduct{}), do: :digital_services_standard
  end

  defimpl Priceable, for: PhysicalProduct do
    def base_price(%PhysicalProduct{price: price}), do: price
    def tax_category(%PhysicalProduct{hazardous: true}), do: :physical_hazardous
    def tax_category(%PhysicalProduct{}), do: :physical_standard
  end

  defimpl Priceable, for: Subscription do
    def base_price(%Subscription{monthly_rate: rate}), do: rate
    def tax_category(%Subscription{}), do: :subscription_service
  end

  @type pricing_result :: %{
          base: Decimal.t(),
          discount_amount: Decimal.t(),
          tax_amount: Decimal.t(),
          total: Decimal.t()
        }

  @doc """
  Calculates the full pricing breakdown for any priceable product.

  Applies the given discount and resolves tax from the product's category.
  """
  @spec calculate(Priceable.t(), Discount.t() | nil, TaxRate.t()) :: pricing_result()
  def calculate(product, discount, tax_rate) do
    base = Priceable.base_price(product)
    discount_amount = compute_discount(base, discount)
    discounted = Decimal.sub(base, discount_amount)
    tax_amount = compute_tax(discounted, product, tax_rate)
    total = Decimal.add(discounted, tax_amount)

    %{
      base: base,
      discount_amount: discount_amount,
      tax_amount: tax_amount,
      total: total
    }
  end

  @doc """
  Returns whether the product qualifies for free shipping.
  """
  @spec qualifies_for_free_shipping?(Priceable.t()) :: boolean()
  def qualifies_for_free_shipping?(product) do
    threshold = Decimal.new("50.00")
    Decimal.compare(Priceable.base_price(product), threshold) in [:gt, :eq]
  end

  defp compute_discount(_base, nil), do: Decimal.new("0")

  defp compute_discount(base, %Discount{type: :percentage, value: pct}) do
    Decimal.mult(base, Decimal.div(pct, Decimal.new("100")))
  end

  defp compute_discount(_base, %Discount{type: :fixed, value: amount}) do
    amount
  end

  defp compute_tax(amount, product, %TaxRate{rates: rates}) do
    category = Priceable.tax_category(product)

    case Map.fetch(rates, category) do
      {:ok, rate} -> Decimal.mult(amount, rate)
      :error -> Decimal.new("0")
    end
  end
end
```
