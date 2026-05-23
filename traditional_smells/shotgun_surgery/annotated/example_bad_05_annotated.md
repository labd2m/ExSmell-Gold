# Example Bad 05 — Annotated

## Metadata

- **Smell Name**: Shotgun Surgery
- **Expected Smell Location**: Functions `calculate_tax_rate/1`, `get_storage_zone/1`, `get_reorder_threshold/1`, and `format_sku_prefix/1` inside `Inventory.ProductManager`
- **Affected Functions**: `calculate_tax_rate/1`, `get_storage_zone/1`, `get_reorder_threshold/1`, `format_sku_prefix/1`
- **Explanation**: The product category logic (`:electronics`, `:clothing`, `:food`) is distributed across four unrelated functions. Adding a new category (e.g., `:pharmaceuticals`) forces four independent edits in separate parts of the module, making it a clear case of Shotgun Surgery.

```elixir
defmodule Inventory.ProductManager do
  @moduledoc """
  Manages product lifecycle including tax classification, warehouse zone assignment,
  reorder thresholds, and SKU generation for categorized inventory items.
  """

  alias Inventory.{Product, WarehouseRouter, StockLedger, TaxAuthority}

  def register_product(attrs) do
    with {:ok, product} <- build_product(attrs),
         {:ok, product} <- assign_warehouse_zone(product),
         {:ok, _}       <- StockLedger.initialize(product) do
      {:ok, product}
    end
  end

  def build_product(attrs) do
    category = Map.fetch!(attrs, :category)
    name     = Map.fetch!(attrs, :name)
    sku_seq  = StockLedger.next_sequence()
    prefix   = format_sku_prefix(category)

    product = %Product{
      name:              name,
      category:          category,
      sku:               "#{prefix}-#{sku_seq}",
      unit_price:        Map.fetch!(attrs, :unit_price),
      tax_rate:          calculate_tax_rate(category),
      reorder_threshold: get_reorder_threshold(category),
      supplier_id:       Map.get(attrs, :supplier_id)
    }

    {:ok, product}
  end

  defp assign_warehouse_zone(product) do
    zone = get_storage_zone(product.category)
    case WarehouseRouter.assign(product, zone) do
      {:ok, location} -> {:ok, %{product | storage_location: location}}
      {:error, _} = err -> err
    end
  end

  def replenish_stock(product_id, quantity) do
    case StockLedger.get(product_id) do
      {:ok, entry} ->
        StockLedger.add_stock(entry, quantity)

      {:error, :not_found} ->
        {:error, :product_not_found}
    end
  end

  def check_reorder_alerts do
    StockLedger.all()
    |> Enum.filter(fn entry ->
      entry.quantity <= get_reorder_threshold(entry.product.category)
    end)
    |> Enum.map(fn entry -> {:reorder_needed, entry.product_id, entry.quantity} end)
  end

  # VALIDATION: SMELL START - Shotgun Surgery [location 1 of 4]
  # VALIDATION: This is a smell because adding a new category (e.g., :pharmaceuticals)
  # requires a new clause here AND in get_storage_zone/1, get_reorder_threshold/1,
  # and format_sku_prefix/1 — four scattered changes for one new category.
  def calculate_tax_rate(:electronics), do: 0.12
  def calculate_tax_rate(:clothing),    do: 0.07
  def calculate_tax_rate(:food),        do: 0.00
  def calculate_tax_rate(_),            do: 0.10
  # VALIDATION: SMELL END [location 1 of 4]

  # VALIDATION: SMELL START - Shotgun Surgery [location 2 of 4]
  # VALIDATION: This is a smell because a new category also requires a new storage zone
  # clause here, independent of the change in calculate_tax_rate/1.
  def get_storage_zone(:electronics), do: :zone_a_climate_controlled
  def get_storage_zone(:clothing),    do: :zone_b_dry_storage
  def get_storage_zone(:food),        do: :zone_c_refrigerated
  def get_storage_zone(_),            do: :zone_d_general
  # VALIDATION: SMELL END [location 2 of 4]

  # VALIDATION: SMELL START - Shotgun Surgery [location 3 of 4]
  # VALIDATION: This is a smell because a new category also requires a new reorder
  # threshold clause here, independent of the previous two locations.
  def get_reorder_threshold(:electronics), do: 5
  def get_reorder_threshold(:clothing),    do: 20
  def get_reorder_threshold(:food),        do: 50
  def get_reorder_threshold(_),            do: 10
  # VALIDATION: SMELL END [location 3 of 4]

  # VALIDATION: SMELL START - Shotgun Surgery [location 4 of 4]
  # VALIDATION: This is a smell because a new category also requires a new SKU prefix
  # clause here, completing the four-location change required for every new category.
  defp format_sku_prefix(:electronics), do: "ELC"
  defp format_sku_prefix(:clothing),    do: "CLT"
  defp format_sku_prefix(:food),        do: "FD"
  defp format_sku_prefix(_),            do: "GEN"
  # VALIDATION: SMELL END [location 4 of 4]

  def archive_product(product_id) do
    case StockLedger.get(product_id) do
      {:ok, entry} when entry.quantity == 0 ->
        StockLedger.archive(product_id)

      {:ok, _entry} ->
        {:error, :stock_remaining}

      {:error, :not_found} ->
        {:error, :product_not_found}
    end
  end

  def list_by_category(category) do
    StockLedger.all()
    |> Enum.filter(fn entry -> entry.product.category == category end)
    |> Enum.map(& &1.product)
  end

  def apply_price_adjustment(product, multiplier) when multiplier > 0 do
    new_price = Float.round(product.unit_price * multiplier, 2)
    %{product | unit_price: new_price}
  end
end
```
