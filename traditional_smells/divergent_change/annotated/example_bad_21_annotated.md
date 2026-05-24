# Annotated Example — Divergent Change

## Metadata

- **Smell name:** Divergent Change
- **Expected smell location:** `ProductCatalog` module (entire module)
- **Affected functions:** `create_product/1`, `update_metadata/2`, `set_price/3`, `apply_bulk_discount/3`, `adjust_stock/3`, `reserve_stock/2`
- **Short explanation:** `ProductCatalog` combines three distinct responsibilities — product catalog/metadata management, pricing and discount logic, and inventory/stock control — forcing changes for completely unrelated reasons (a new pricing strategy, a warehouse policy change, or an SEO metadata update).

---

```elixir
defmodule Store.ProductCatalog do
  @moduledoc """
  Manages product information, pricing, and inventory for the Store domain.
  """

  require Logger

  alias Store.Repo
  alias Store.Products.Product
  alias Store.Inventory.StockEntry

  # VALIDATION: SMELL START - Divergent Change
  # VALIDATION: This is a smell because the module mixes three independent
  # axes of change: (1) product catalog/metadata, (2) pricing and discount
  # policies, and (3) stock/inventory management. Each domain can evolve
  # for reasons completely unrelated to the others.

  ## ──────────────────────────────────────────────
  ## Reason to modify (1): Product catalog / metadata
  ## ──────────────────────────────────────────────

  @doc "Creates a new product entry in the catalog."
  def create_product(attrs) do
    changeset = Product.changeset(%Product{}, attrs)

    case Repo.insert(changeset) do
      {:ok, product} ->
        Logger.info("Product created: #{product.sku} — #{product.name}")
        {:ok, product}

      {:error, cs} ->
        Logger.warning("Product creation failed: #{inspect(cs.errors)}")
        {:error, cs}
    end
  end

  @doc "Updates descriptive metadata for an existing product."
  def update_metadata(%Product{} = product, attrs) do
    allowed = [:name, :description, :category, :tags, :images, :seo_title, :seo_description]
    filtered = Map.take(attrs, allowed)

    product
    |> Product.changeset(filtered)
    |> Repo.update()
  end

  @doc "Archives a product so it no longer appears in the public catalog."
  def archive_product(%Product{} = product) do
    product
    |> Product.changeset(%{archived_at: DateTime.utc_now(), status: :archived})
    |> Repo.update()
  end

  ## ──────────────────────────────────────────────
  ## Reason to modify (2): Pricing / discount policy
  ## ──────────────────────────────────────────────

  @doc "Sets the base price for a product in the given currency."
  def set_price(%Product{} = product, amount, currency \\ "USD") do
    unless valid_currency?(currency) do
      {:error, :unsupported_currency}
    else
      product
      |> Product.changeset(%{price: amount, currency: currency})
      |> Repo.update()
    end
  end

  @doc "Applies a bulk discount when a minimum quantity threshold is met."
  def apply_bulk_discount(%Product{} = product, min_qty, discount_pct)
      when is_integer(min_qty) and min_qty > 0 and discount_pct > 0 and discount_pct <= 100 do
    tier = %{
      min_quantity: min_qty,
      discount_percent: discount_pct,
      effective_price:
        product.price
        |> Decimal.mult(Decimal.new(100 - discount_pct))
        |> Decimal.div(Decimal.new(100))
    }

    current_tiers = product.bulk_discount_tiers || []
    updated_tiers = Enum.sort_by([tier | current_tiers], & &1.min_quantity)

    product
    |> Product.changeset(%{bulk_discount_tiers: updated_tiers})
    |> Repo.update()
  end

  def apply_bulk_discount(_, _, _), do: {:error, :invalid_discount_parameters}

  ## ──────────────────────────────────────────────
  ## Reason to modify (3): Inventory / stock control
  ## ──────────────────────────────────────────────

  @doc "Adjusts the stock level for a product at a given warehouse."
  def adjust_stock(%Product{} = product, warehouse_id, delta) do
    entry =
      Repo.get_by(StockEntry,
        product_id: product.id,
        warehouse_id: warehouse_id
      ) || %StockEntry{}

    new_qty = (entry.quantity || 0) + delta

    if new_qty < 0 do
      {:error, :insufficient_stock}
    else
      entry
      |> StockEntry.changeset(%{
        product_id: product.id,
        warehouse_id: warehouse_id,
        quantity: new_qty,
        last_updated_at: DateTime.utc_now()
      })
      |> Repo.insert_or_update()
    end
  end

  @doc "Reserves a quantity of stock for a pending order, reducing available units."
  def reserve_stock(%Product{} = product, quantity) when quantity > 0 do
    available = total_available_stock(product.id)

    if available >= quantity do
      Logger.info("Reserving #{quantity} units of product #{product.id}")
      {:ok, %{product_id: product.id, reserved: quantity}}
    else
      {:error, :not_enough_stock}
    end
  end

  def reserve_stock(_, _), do: {:error, :invalid_quantity}

  # VALIDATION: SMELL END

  ## ── Private helpers ──────────────────────

  defp valid_currency?(code) when code in ["USD", "EUR", "GBP", "BRL"], do: true
  defp valid_currency?(_), do: false

  defp total_available_stock(product_id) do
    import Ecto.Query
    Repo.aggregate(
      from(s in StockEntry, where: s.product_id == ^product_id),
      :sum,
      :quantity
    ) || 0
  end
end
```
