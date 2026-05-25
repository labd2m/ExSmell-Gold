```elixir
defmodule ProductCatalog do
  @moduledoc """
  Manages the full product catalog lifecycle: creation, variants, pricing,
  discount rules, Elasticsearch indexing, sitemap generation, and CSV import.
  """

  require Logger
  alias Catalog.Repo
  alias Catalog.Product
  alias Catalog.ProductVariant
  alias Catalog.PricingRule

  @search_index "products"
  @min_price Decimal.new("0.01")


  def create_product(attrs) do
    changeset = Product.changeset(%Product{}, Map.put(attrs, :status, :draft))

    case Repo.insert(changeset) do
      {:ok, product} ->
        Logger.info("Product #{product.id} (#{product.sku}) created")
        {:ok, product}

      {:error, cs} ->
        {:error, cs}
    end
  end

  def update_product(%Product{} = product, attrs) do
    product
    |> Product.changeset(Map.drop(attrs, [:sku, :status]))
    |> Repo.update()
  end

  def publish_product(%Product{status: :published}), do: {:error, :already_published}

  def publish_product(%Product{} = product) do
    with {:ok, updated} <-
           product
           |> Product.changeset(%{status: :published, published_at: DateTime.utc_now()})
           |> Repo.update() do
      index_for_search(updated)
      {:ok, updated}
    end
  end

  def unpublish_product(%Product{} = product) do
    with {:ok, updated} <-
           product
           |> Product.changeset(%{status: :draft})
           |> Repo.update() do
      Elasticsearch.delete_document(@search_index, updated.id)
      {:ok, updated}
    end
  end


  def add_variant(%Product{} = product, variant_attrs) do
    attrs = Map.merge(variant_attrs, %{product_id: product.id})

    case Repo.insert(ProductVariant.changeset(%ProductVariant{}, attrs)) do
      {:ok, variant} ->
        Logger.info("Variant #{variant.id} added to product #{product.id}")
        {:ok, variant}

      {:error, cs} ->
        {:error, cs}
    end
  end


  def update_pricing(%Product{} = product, %{price: price} = pricing_attrs) do
    if Decimal.compare(price, @min_price) == :lt do
      {:error, :price_below_minimum}
    else
      product
      |> Product.changeset(Map.take(pricing_attrs, [:price, :compare_at_price, :cost_price]))
      |> Repo.update()
    end
  end

  def apply_bulk_discount(product_ids, discount_pct) when discount_pct > 0 and discount_pct < 100 do
    multiplier = Decimal.from_float(1 - discount_pct / 100)

    Enum.each(product_ids, fn pid ->
      product = Repo.get!(Product, pid)
      new_price = product.price |> Decimal.mult(multiplier) |> Decimal.round(2)

      product
      |> Product.changeset(%{compare_at_price: product.price, price: new_price})
      |> Repo.update!()
    end)

    Logger.info("Bulk discount of #{discount_pct}% applied to #{length(product_ids)} products")
    :ok
  end

  def apply_bulk_discount(_, _), do: {:error, :invalid_discount_percentage}

  def create_pricing_rule(product_id, rule_attrs) do
    attrs = Map.merge(rule_attrs, %{product_id: product_id, active: true})

    case Repo.insert(PricingRule.changeset(%PricingRule{}, attrs)) do
      {:ok, rule} -> {:ok, rule}
      {:error, cs} -> {:error, cs}
    end
  end


  def index_for_search(%Product{} = product) do
    product = Repo.preload(product, [:variants, :category])

    document = %{
      id: product.id,
      sku: product.sku,
      name: product.name,
      description: product.description,
      price: product.price,
      category: product.category && product.category.name,
      tags: product.tags,
      variant_skus: Enum.map(product.variants, & &1.sku),
      published_at: product.published_at
    }

    case Elasticsearch.index_document(@search_index, document) do
      :ok ->
        Logger.debug("Product #{product.id} indexed for search")
        :ok

      {:error, reason} ->
        Logger.error("Failed to index product #{product.id}: #{inspect(reason)}")
        {:error, reason}
    end
  end


  def generate_sitemap_entry(%Product{status: :published} = product) do
    """
    <url>
      <loc>https://shop.example.com/products/
      <lastmod>
      <changefreq>weekly</changefreq>
      <priority>0.8</priority>
    </url>
    """
  end

  def generate_sitemap_entry(_), do: nil


  def import_from_csv(csv_path) do
    csv_path
    |> File.stream!()
    |> CSV.decode(headers: true)
    |> Enum.reduce({0, []}, fn
      {:ok, row}, {count, errors} ->
        attrs = %{
          sku: row["sku"],
          name: row["name"],
          description: row["description"],
          price: Decimal.new(row["price"]),
          status: :draft
        }

        case create_product(attrs) do
          {:ok, _}    -> {count + 1, errors}
          {:error, e} -> {count, [{row["sku"], e} | errors]}
        end

      {:error, message}, {count, errors} ->
        {count, [{:parse_error, message} | errors]}
    end)
    |> then(fn {created, errors} ->
      Logger.info("CSV import complete: #{created} created, #{length(errors)} errors")
      %{created: created, errors: Enum.reverse(errors)}
    end)
  end
end
```
