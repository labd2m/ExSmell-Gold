# Annotated Example – Code Smell

| Field | Value |
|---|---|
| **Smell name** | Long Parameter List |
| **Expected smell location** | `Inventory.Products.create_product/12` |
| **Affected function(s)** | `create_product/12` |
| **Short explanation** | Twelve parameters covering product identity, pricing, stock thresholds, physical dimensions, and catalogue flags are passed individually. The parameters naturally form at least three groups (`%ProductInfo{}`, `%PricingConfig{}`, `%PhysicalSpec{}`), and their flat enumeration in a function signature is hard to read and error-prone. |

```elixir
defmodule Inventory.Products do
  @moduledoc """
  Manages product lifecycle within the inventory service.
  """

  require Logger

  @max_sku_length 64
  @min_reorder_point 0

  # VALIDATION: SMELL START - Long Parameter List
  # VALIDATION: This is a smell because 12 positional parameters are
  # required. A caller could accidentally swap weight_grams with
  # stock_quantity, or pass reorder_point after restock_quantity and the
  # compiler would not catch it. Grouping into %ProductInfo{} and
  # %StockConfig{} structs would make the intent explicit and the interface
  # resilient to extension.
  def create_product(
        sku,
        name,
        description,
        unit_price,
        cost_price,
        stock_quantity,
        reorder_point,
        restock_quantity,
        weight_grams,
        category,
        is_active,
        is_taxable
      ) do
    # VALIDATION: SMELL END
    with :ok <- validate_sku(sku),
         :ok <- validate_name(name),
         :ok <- validate_prices(unit_price, cost_price),
         :ok <- validate_stock_params(stock_quantity, reorder_point, restock_quantity),
         :ok <- validate_weight(weight_grams) do
      product = %{
        id: generate_product_id(),
        sku: String.upcase(String.trim(sku)),
        name: String.trim(name),
        description: description,
        pricing: %{
          unit_price: unit_price,
          cost_price: cost_price,
          margin: compute_margin(unit_price, cost_price),
          is_taxable: is_taxable
        },
        stock: %{
          quantity: stock_quantity,
          reorder_point: reorder_point,
          restock_quantity: restock_quantity,
          status: stock_status(stock_quantity, reorder_point)
        },
        physical: %{
          weight_grams: weight_grams
        },
        category: category,
        is_active: is_active,
        inserted_at: NaiveDateTime.utc_now()
      }

      case persist_product(product) do
        {:ok, saved} ->
          Logger.info("Product created: SKU=#{saved.sku}")
          {:ok, saved}

        {:error, :sku_conflict} ->
          {:error, "SKU #{sku} already exists"}

        {:error, reason} ->
          Logger.error("Failed to create product #{sku}: #{inspect(reason)}")
          {:error, :persistence_failed}
      end
    end
  end

  defp validate_sku(sku) when byte_size(sku) > 0 and byte_size(sku) <= @max_sku_length, do: :ok
  defp validate_sku(sku) when byte_size(sku) > @max_sku_length,
    do: {:error, "SKU exceeds #{@max_sku_length} characters"}
  defp validate_sku(_), do: {:error, "SKU must not be blank"}

  defp validate_name(n) when byte_size(n) > 0, do: :ok
  defp validate_name(_), do: {:error, "name must not be blank"}

  defp validate_prices(unit, cost) when unit > 0 and cost >= 0, do: :ok
  defp validate_prices(_, _), do: {:error, "prices must be non-negative (unit must be positive)"}

  defp validate_stock_params(qty, reorder, restock) when qty >= 0 and reorder >= @min_reorder_point and restock > 0, do: :ok
  defp validate_stock_params(_, _, _), do: {:error, "invalid stock parameters"}

  defp validate_weight(w) when w > 0, do: :ok
  defp validate_weight(_), do: {:error, "weight_grams must be positive"}

  defp compute_margin(unit, cost) when unit > 0 do
    Float.round((unit - cost) / unit * 100, 2)
  end
  defp compute_margin(_, _), do: 0.0

  defp stock_status(qty, reorder) when qty <= reorder, do: :low
  defp stock_status(0, _), do: :out_of_stock
  defp stock_status(_, _), do: :ok

  defp persist_product(product) do
    {:ok, Map.put(product, :persisted, true)}
  end

  defp generate_product_id do
    :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
  end
end
```
