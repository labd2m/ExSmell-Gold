# Smell: Shotgun Surgery

- **Smell Name:** Shotgun Surgery
- **Expected Smell Location:** `MyApp.Catalog.PricingEngine`, `MyApp.Catalog.TaxCalculator`, `MyApp.Catalog.StockAllocator`
- **Affected Functions:** `PricingEngine.apply_rules/2`, `TaxCalculator.compute/2`, `StockAllocator.reserve/2`
- **Explanation:** Adding a new product category (e.g., `:electronics`) requires small but mandatory changes scattered across all three modules: pricing rules in `PricingEngine`, tax rates in `TaxCalculator`, and allocation strategies in `StockAllocator`. Category-specific behavior is spread across modules rather than isolated.

```elixir
# VALIDATION: SMELL START - Shotgun Surgery
# VALIDATION: This is a smell because introducing a new product category (e.g., :electronics)
# VALIDATION: requires simultaneous changes in PricingEngine.apply_rules/2,
# VALIDATION: TaxCalculator.compute/2, and StockAllocator.reserve/2.
# VALIDATION: Category logic is scattered across three separate modules,
# VALIDATION: making incomplete updates highly likely.

defmodule MyApp.Catalog.PricingEngine do
  @moduledoc """
  Applies category-specific pricing rules to product listings.
  Rules include margin floors, discount caps, and promotional eligibility.
  Prices are returned in the store's base currency (BRL).
  """

  alias MyApp.Catalog.PromotionChecker

  def apply_rules(%{category: :clothing} = product, context) do
    base = product.cost_price * 2.2

    price =
      if PromotionChecker.active_promotion?(:clothing, context.date) do
        max(base * 0.85, product.cost_price * 1.1)
      else
        base
      end

    {:ok, %{product_id: product.id, final_price: Float.round(price, 2), currency: "BRL"}}
  end

  def apply_rules(%{category: :books} = product, _context) do
    price = product.cost_price * 1.35
    {:ok, %{product_id: product.id, final_price: Float.round(price, 2), currency: "BRL"}}
  end

  def apply_rules(%{category: :food} = product, context) do
    base = product.cost_price * 1.6

    price =
      if product.perishable? && Date.diff(product.expiry_date, context.date) <= 3 do
        base * 0.7
      else
        base
      end

    {:ok, %{product_id: product.id, final_price: Float.round(price, 2), currency: "BRL"}}
  end

  def apply_rules(%{category: unknown}, _context) do
    {:error, {:no_pricing_rule, unknown}}
  end
end

defmodule MyApp.Catalog.TaxCalculator do
  @moduledoc """
  Computes applicable taxes for each product category following Brazilian tax law.
  Returns itemized tax components (ICMS, PIS, COFINS, IPI) in addition to the
  total tax amount and effective rate.
  """

  @icms_clothing 0.12
  @pis_clothing 0.0165
  @cofins_clothing 0.076

  @icms_books 0.00
  @pis_books 0.00
  @cofins_books 0.00

  @icms_food 0.07
  @pis_food 0.0065
  @cofins_food 0.03

  def compute(%{category: :clothing} = product, quantity) do
    subtotal = product.final_price * quantity
    icms = subtotal * @icms_clothing
    pis = subtotal * @pis_clothing
    cofins = subtotal * @cofins_clothing
    total_tax = icms + pis + cofins

    {:ok,
     %{
       subtotal: subtotal,
       icms: Float.round(icms, 2),
       pis: Float.round(pis, 2),
       cofins: Float.round(cofins, 2),
       ipi: 0.00,
       total_tax: Float.round(total_tax, 2),
       effective_rate: @icms_clothing + @pis_clothing + @cofins_clothing
     }}
  end

  def compute(%{category: :books} = product, quantity) do
    subtotal = product.final_price * quantity

    {:ok,
     %{
       subtotal: subtotal,
       icms: 0.00,
       pis: 0.00,
       cofins: 0.00,
       ipi: 0.00,
       total_tax: 0.00,
       effective_rate: 0.00
     }}
  end

  def compute(%{category: :food} = product, quantity) do
    subtotal = product.final_price * quantity
    icms = subtotal * @icms_food
    pis = subtotal * @pis_food
    cofins = subtotal * @cofins_food
    total_tax = icms + pis + cofins

    {:ok,
     %{
       subtotal: subtotal,
       icms: Float.round(icms, 2),
       pis: Float.round(pis, 2),
       cofins: Float.round(cofins, 2),
       ipi: 0.00,
       total_tax: Float.round(total_tax, 2),
       effective_rate: @icms_food + @pis_food + @cofins_food
     }}
  end

  def compute(%{category: unknown}, _quantity) do
    {:error, {:no_tax_rule, unknown}}
  end
end

defmodule MyApp.Catalog.StockAllocator do
  @moduledoc """
  Reserves inventory for an order based on product category.
  Different categories have different allocation strategies:
  clothing uses size-specific bins, books use a flat SKU pool,
  and food uses FIFO batches to minimize waste.
  """

  alias MyApp.Warehouse.{BinStore, SkuPool, BatchStore}

  def reserve(%{category: :clothing} = product, %{size: size, quantity: quantity}) do
    bin_key = "#{product.sku}-#{size}"

    case BinStore.decrement(bin_key, quantity) do
      {:ok, remaining} ->
        {:ok, %{reserved: quantity, bin: bin_key, remaining_stock: remaining}}

      {:error, :insufficient_stock} ->
        {:error, {:out_of_stock, product.sku, size}}
    end
  end

  def reserve(%{category: :books} = product, %{quantity: quantity}) do
    case SkuPool.decrement(product.sku, quantity) do
      {:ok, remaining} ->
        {:ok, %{reserved: quantity, sku: product.sku, remaining_stock: remaining}}

      {:error, :insufficient_stock} ->
        {:error, {:out_of_stock, product.sku}}
    end
  end

  def reserve(%{category: :food} = product, %{quantity: quantity}) do
    case BatchStore.consume_fifo(product.sku, quantity) do
      {:ok, batches_consumed} ->
        total_reserved = Enum.sum(Enum.map(batches_consumed, & &1.quantity))
        {:ok, %{reserved: total_reserved, batches: batches_consumed}}

      {:error, :insufficient_stock} ->
        {:error, {:out_of_stock, product.sku}}
    end
  end

  def reserve(%{category: unknown}, _opts) do
    {:error, {:unsupported_category, unknown}}
  end
end
# VALIDATION: SMELL END
```
