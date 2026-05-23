# Code Smell Example – Annotated

- **Smell:** Feature Envy
- **Expected smell location:** `Catalog.SearchIndexBuilder.build_product_document/1`
- **Affected function(s):** `build_product_document/1`
- **Explanation:** `build_product_document/1` calls `Product.get_brand/1`, `Product.list_variants/1`, `Product.active_media/1`, `Product.list_tags/1`, `Product.primary_category/1`, and `Product.searchable_attributes/1`, while reading multiple fields from the product struct directly. `SearchIndexBuilder` contributes only Algolia/Elasticsearch document formatting. The function envies `Product` and should live there.

```elixir
defmodule Catalog.SearchIndexBuilder do
  @moduledoc """
  Builds and submits product documents to the search index (Algolia).
  Triggered on product publish events and nightly re-index jobs.
  Each document is a flat map optimised for faceted search, text
  ranking, and personalisation signals.
  """

  alias Catalog.{Product, Brand, Category, ProductVariant}
  alias Search.{AlgoliaClient, IndexConfig}

  @index_name     "products"
  @max_image_urls 5
  @text_truncate  500

  # ------------------------------------------------------------------
  # Public API
  # ------------------------------------------------------------------

  @doc """
  Indexes a single product by ID.
  Returns `{:ok, object_id}` or `{:error, reason}`.
  """
  @spec index_product(String.t()) :: {:ok, String.t()} | {:error, term()}
  def index_product(product_id) do
    product = Product.get!(product_id)
    config  = IndexConfig.for_index(@index_name)

    document = build_product_document(product)
    AlgoliaClient.save_object(@index_name, document, config)
  end

  @doc """
  Performs a full re-index of all published products.
  Streams in batches to avoid memory pressure.
  """
  @spec reindex_all() :: {:ok, non_neg_integer()} | {:error, term()}
  def reindex_all() do
    config = IndexConfig.for_index(@index_name)

    count =
      Product.stream_published()
      |> Stream.map(&build_product_document/1)
      |> Stream.chunk_every(100)
      |> Enum.reduce(0, fn batch, acc ->
        AlgoliaClient.batch_save(@index_name, batch, config)
        acc + length(batch)
      end)

    {:ok, count}
  end

  # ------------------------------------------------------------------
  # Private helpers
  # ------------------------------------------------------------------

  # VALIDATION: SMELL START - Feature Envy
  # VALIDATION: This is a smell because build_product_document/1 is defined
  # VALIDATION: in SearchIndexBuilder but almost all of its logic belongs to
  # VALIDATION: the Product module. It calls:
  # VALIDATION:   - Product.get_brand/1
  # VALIDATION:   - Product.list_variants/1
  # VALIDATION:   - Product.active_media/1
  # VALIDATION:   - Product.list_tags/1
  # VALIDATION:   - Product.primary_category/1
  # VALIDATION:   - Product.searchable_attributes/1
  # VALIDATION: and reads product.id, product.slug, product.name,
  # VALIDATION: product.description, product.published_at,
  # VALIDATION: product.average_rating, product.review_count,
  # VALIDATION: and product.rank_boost directly from the struct.
  # VALIDATION: SearchIndexBuilder contributes only the structural
  # VALIDATION: flattening and field truncation.
  # VALIDATION: This function belongs in the Product module.
  defp build_product_document(product) do
    brand      = Product.get_brand(product)
    variants   = Product.list_variants(product)
    media      = Product.active_media(product)
    tags       = Product.list_tags(product)
    category   = Product.primary_category(product)
    attributes = Product.searchable_attributes(product)

    prices      = Enum.map(variants, & &1.price)
    min_price   = Enum.min(prices, fn -> nil end)
    max_price   = Enum.max(prices, fn -> nil end)
    in_stock    = Enum.any?(variants, &ProductVariant.in_stock?/1)
    sku_list    = Enum.map(variants, & &1.sku)

    image_urls =
      media
      |> Enum.take(@max_image_urls)
      |> Enum.map(& &1.cdn_url)

    %{
      objectID:          product.id,
      slug:              product.slug,
      name:              product.name,
      description:       truncate(product.description, @text_truncate),
      brand_id:          brand.id,
      brand_name:        Brand.display_name(brand),
      brand_slug:        brand.slug,
      category_id:       category && category.id,
      category_name:     category && Category.full_path(category),
      category_level_1:  category && Category.level_name(category, 1),
      category_level_2:  category && Category.level_name(category, 2),
      tags:              Enum.map(tags, & &1.slug),
      skus:              sku_list,
      variant_count:     length(variants),
      min_price:         min_price,
      max_price:         max_price,
      in_stock:          in_stock,
      image_urls:        image_urls,
      attributes:        attributes,
      average_rating:    product.average_rating,
      review_count:      product.review_count,
      rank_boost:        product.rank_boost,
      published_at:      published_at_unix(product.published_at)
    }
  end
  # VALIDATION: SMELL END

  defp truncate(nil, _limit),    do: nil
  defp truncate(text, limit) when byte_size(text) <= limit, do: text
  defp truncate(text, limit) do
    text
    |> String.slice(0, limit)
    |> String.trim_trailing()
    |> Kernel.<>("…")
  end

  defp published_at_unix(nil),             do: nil
  defp published_at_unix(%DateTime{} = dt), do: DateTime.to_unix(dt)
end
```
