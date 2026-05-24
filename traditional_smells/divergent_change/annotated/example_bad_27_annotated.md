# Annotated Example — Divergent Change

## Metadata

- **Smell name:** Divergent Change
- **Expected smell location:** `ProductCatalog` module (entire module)
- **Affected functions:** `create_product/1`, `update_product/2`, `apply_bulk_discount/2`, `recalculate_price/2`, `index_for_search/1`, `search_products/2`
- **Explanation:** `ProductCatalog` merges product CRUD, pricing/discount logic, and full-text search indexing into a single module. Each group is driven by different change forces: product attributes evolve with business needs, pricing rules change with promotions and cost structures, and search indexing changes with search engine upgrades or relevance tuning.

---

```elixir
defmodule MyApp.ProductCatalog do
  @moduledoc """
  Manages product data, pricing rules, and search indexing
  for the e-commerce storefront.
  """

  alias MyApp.Repo
  alias MyApp.Schemas.Product
  alias MyApp.Search.Elasticsearch
  import Ecto.Query

  # VALIDATION: SMELL START - Divergent Change
  # VALIDATION: This is a smell because product lifecycle management, pricing
  # and discount calculation, and search indexing are three independent concerns.
  # A change in discount policy, search mapping schema, or product data structure
  # each forces unrelated edits to this single module.

  ## ── Product Management ──────────────────────────────────────────────────────

  @doc """
  Creates a new product with the supplied attributes.
  """
  def create_product(attrs) do
    %Product{}
    |> Product.changeset(attrs)
    |> Repo.insert()
    |> case do
      {:ok, product} = result ->
        index_for_search(product)
        result

      error ->
        error
    end
  end

  @doc """
  Updates an existing product. Re-indexes the product after a successful save.
  """
  def update_product(%Product{} = product, attrs) do
    product
    |> Product.changeset(attrs)
    |> Repo.update()
    |> case do
      {:ok, updated} = result ->
        index_for_search(updated)
        result

      error ->
        error
    end
  end

  @doc """
  Fetches a product by its SKU.
  """
  def get_by_sku(sku) do
    Repo.get_by(Product, sku: sku)
  end

  @doc """
  Lists all active products, optionally filtered by category.
  """
  def list_active(category \\ nil) do
    base = from p in Product, where: p.active == true

    case category do
      nil -> base
      cat -> from p in base, where: p.category == ^cat
    end
    |> Repo.all()
  end

  ## ── Pricing & Discounts ─────────────────────────────────────────────────────

  @doc """
  Applies a bulk discount percentage to all products in a given category.
  """
  def apply_bulk_discount(category, discount_pct) when discount_pct > 0 and discount_pct < 100 do
    multiplier = (100 - discount_pct) / 100.0

    from(p in Product, where: p.category == ^category and p.active == true)
    |> Repo.update_all(
      set: [discount_percentage: discount_pct],
      inc: []
    )

    from(p in Product, where: p.category == ^category and p.active == true)
    |> Repo.all()
    |> Enum.each(fn product ->
      new_price = round(product.base_price_cents * multiplier)

      product
      |> Product.changeset(%{discounted_price_cents: new_price, discount_percentage: discount_pct})
      |> Repo.update!()
    end)

    :ok
  end

  @doc """
  Recalculates the final price of a product considering cost, margin, and taxes.
  """
  def recalculate_price(%Product{} = product, tax_rate_pct) do
    margin_multiplier = 1 + product.target_margin_pct / 100.0
    tax_multiplier = 1 + tax_rate_pct / 100.0
    base = round(product.cost_cents * margin_multiplier)
    final = round(base * tax_multiplier)

    product
    |> Product.changeset(%{base_price_cents: base, final_price_cents: final, tax_rate_pct: tax_rate_pct})
    |> Repo.update()
  end

  ## ── Search Indexing ─────────────────────────────────────────────────────────

  @doc """
  Sends a product document to Elasticsearch for full-text search indexing.
  """
  def index_for_search(%Product{} = product) do
    doc = %{
      id: product.id,
      name: product.name,
      description: product.description,
      category: product.category,
      sku: product.sku,
      price_cents: product.final_price_cents || product.base_price_cents,
      active: product.active,
      tags: product.tags || [],
      indexed_at: DateTime.utc_now()
    }

    Elasticsearch.index_document("products", product.id, doc)
  end

  @doc """
  Full-text search across products using Elasticsearch.
  """
  def search_products(query_string, opts \\ []) do
    size = Keyword.get(opts, :limit, 20)
    category_filter = Keyword.get(opts, :category)

    es_query = build_es_query(query_string, category_filter, size)

    case Elasticsearch.search("products", es_query) do
      {:ok, %{hits: hits}} -> {:ok, Enum.map(hits, & &1["_source"])}
      {:error, _} = err -> err
    end
  end

  defp build_es_query(q, nil, size) do
    %{size: size, query: %{match: %{name: q}}}
  end

  defp build_es_query(q, category, size) do
    %{
      size: size,
      query: %{
        bool: %{
          must: [%{match: %{name: q}}],
          filter: [%{term: %{category: category}}]
        }
      }
    }
  end

  # VALIDATION: SMELL END
end
```
