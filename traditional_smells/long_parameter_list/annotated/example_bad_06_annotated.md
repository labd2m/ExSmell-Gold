# Annotated Example 06 — Long Parameter List

## Metadata

- **Smell name:** Long Parameter List
- **Expected smell location:** `Inventory.Products.upsert_product/12`
- **Affected function(s):** `upsert_product/12`
- **Short explanation:** The function accepts 12 flat parameters covering product identity, pricing, stock, dimensions, and metadata. These naturally belong in a `Product` struct or an attrs map, not a flat positional list.

---

```elixir
defmodule Inventory.Products do
  @moduledoc """
  Manages product records, stock levels, and pricing in the inventory system.
  """

  require Logger

  alias Inventory.{Product, StockLedger, PricingEngine, Repo}

  @statuses [:active, :inactive, :discontinued, :draft]
  @default_tax_rate Decimal.new("0.08")

  # VALIDATION: SMELL START - Long Parameter List
  # VALIDATION: This is a smell because 12 separate positional parameters are required.
  # VALIDATION: Product identity, pricing info, physical specs, and control flags should
  # VALIDATION: be encapsulated in a Product struct or a descriptive attrs map.
  def upsert_product(
        sku,
        name,
        description,
        category_id,
        supplier_id,
        unit_price,
        cost_price,
        stock_quantity,
        reorder_threshold,
        weight_grams,
        status,
        taxable
      ) do
    # VALIDATION: SMELL END

    with :ok <- validate_sku(sku),
         :ok <- validate_prices(unit_price, cost_price),
         :ok <- validate_stock(stock_quantity, reorder_threshold),
         :ok <- validate_status(status) do

      effective_price = PricingEngine.compute_effective_price(unit_price, category_id)

      tax_rate = if taxable, do: @default_tax_rate, else: Decimal.new(0)

      product_attrs = %{
        sku: sku,
        name: name,
        description: description,
        category_id: category_id,
        supplier_id: supplier_id,
        unit_price: unit_price,
        effective_price: effective_price,
        cost_price: cost_price,
        margin: Decimal.sub(effective_price, cost_price),
        tax_rate: tax_rate,
        stock_quantity: stock_quantity,
        reorder_threshold: reorder_threshold,
        weight_grams: weight_grams,
        status: status,
        updated_at: DateTime.utc_now()
      }

      case Repo.get_by(Product, sku: sku) do
        nil ->
          new_product = Map.put(product_attrs, :inserted_at, DateTime.utc_now())

          case Repo.insert(struct(Product, new_product)) do
            {:ok, product} ->
              StockLedger.record_initial_stock(product.sku, stock_quantity)
              Logger.info("Product created: #{sku} — #{name}")
              {:ok, product}

            {:error, reason} ->
              Logger.error("Failed to create product #{sku}: #{inspect(reason)}")
              {:error, reason}
          end

        existing ->
          prev_qty = existing.stock_quantity

          case Repo.update(struct(existing, product_attrs)) do
            {:ok, product} ->
              if product.stock_quantity != prev_qty do
                StockLedger.record_adjustment(sku, prev_qty, product.stock_quantity)
              end

              Logger.info("Product updated: #{sku}")
              {:ok, product}

            {:error, reason} ->
              Logger.error("Failed to update product #{sku}: #{inspect(reason)}")
              {:error, reason}
          end
      end
    end
  end

  def mark_discontinued(sku) do
    case Repo.get_by(Product, sku: sku) do
      nil -> {:error, :not_found}
      product -> Repo.update(struct(product, status: :discontinued))
    end
  end

  defp validate_sku(sku) when is_binary(sku) and byte_size(sku) > 0, do: :ok
  defp validate_sku(_), do: {:error, :invalid_sku}

  defp validate_prices(unit, cost)
       when is_struct(unit, Decimal) and is_struct(cost, Decimal) do
    if Decimal.gt?(unit, Decimal.new(0)) and Decimal.gt?(cost, Decimal.new(0)),
      do: :ok,
      else: {:error, :non_positive_price}
  end

  defp validate_prices(_, _), do: {:error, :invalid_price_type}

  defp validate_stock(qty, threshold) when is_integer(qty) and qty >= 0 and is_integer(threshold) and threshold >= 0,
    do: :ok

  defp validate_stock(_, _), do: {:error, :invalid_stock_values}

  defp validate_status(s) when s in @statuses, do: :ok
  defp validate_status(s), do: {:error, {:invalid_status, s}}
end
```
