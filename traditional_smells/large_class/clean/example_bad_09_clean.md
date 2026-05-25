```elixir
defmodule MyApp.ProductCatalog do
  @moduledoc """
  Full product catalog management: products, categories, search,
  SEO, variants, featured items, and bulk import.
  """

  require Logger
  import Ecto.Query

  alias MyApp.Repo
  alias MyApp.Products.{Product, Category, ProductCategory, ProductVariant, SeoMetadata}


  def create_product(attrs) do
    changeset = Product.changeset(%Product{}, Map.put(attrs, :status, :draft))

    case Repo.insert(changeset) do
      {:ok, product} ->
        Logger.info("Product #{product.id} created: #{product.name}")
        {:ok, product}

      {:error, _} = err ->
        err
    end
  end

  def update_product(product_id, attrs) do
    product = Repo.get!(Product, product_id)
    allowed = Map.take(attrs, [:name, :description, :price_cents, :sku, :weight_oz, :status])

    product
    |> Product.changeset(allowed)
    |> Repo.update()
  end

  def archive_product(product_id) do
    product = Repo.get!(Product, product_id)

    if product.status == :archived do
      {:error, :already_archived}
    else
      Repo.update!(Product.changeset(product, %{status: :archived, archived_at: DateTime.utc_now()}))
      {:ok, :archived}
    end
  end

  def publish_product(product_id) do
    product = Repo.get!(Product, product_id)

    cond do
      product.status == :published ->
        {:error, :already_published}

      is_nil(product.description) or String.length(product.description) < 10 ->
        {:error, :incomplete_description}

      is_nil(product.price_cents) ->
        {:error, :missing_price}

      true ->
        Repo.update!(Product.changeset(product, %{status: :published, published_at: DateTime.utc_now()}))
        {:ok, :published}
    end
  end


  def add_to_category(product_id, category_id) do
    existing = Repo.get_by(ProductCategory, product_id: product_id, category_id: category_id)

    unless existing do
      Repo.insert!(%ProductCategory{product_id: product_id, category_id: category_id})
    end

    :ok
  end

  def remove_from_category(product_id, category_id) do
    case Repo.get_by(ProductCategory, product_id: product_id, category_id: category_id) do
      nil  -> {:error, :not_found}
      link -> Repo.delete!(link); :ok
    end
  end

  def list_by_category(category_slug, opts \\ []) do
    limit  = opts[:limit]  || 20
    offset = opts[:offset] || 0

    from(p in Product,
      join: pc in ProductCategory, on: pc.product_id == p.id,
      join: c in Category, on: c.id == pc.category_id,
      where: c.slug == ^category_slug and p.status == :published,
      order_by: [desc: p.inserted_at],
      limit:  ^limit,
      offset: ^offset
    )
    |> Repo.all()
  end


  def search_products(query_string, opts \\ []) when is_binary(query_string) do
    limit  = opts[:limit]  || 20
    like   = "%#{query_string}%"

    base =
      from(p in Product,
        where: p.status == :published
          and (ilike(p.name, ^like) or ilike(p.description, ^like) or ilike(p.sku, ^like)),
        order_by: [desc: p.inserted_at],
        limit: ^limit
      )

    base =
      if min_price = opts[:min_price] do
        from p in base, where: p.price_cents >= ^min_price
      else
        base
      end

    base =
      if max_price = opts[:max_price] do
        from p in base, where: p.price_cents <= ^max_price
      else
        base
      end

    Repo.all(base)
  end


  def update_seo_metadata(product_id, meta_attrs) do
    allowed  = Map.take(meta_attrs, [:meta_title, :meta_description, :og_image_url, :canonical_url])
    existing = Repo.get_by(SeoMetadata, product_id: product_id)

    if existing do
      existing |> SeoMetadata.changeset(allowed) |> Repo.update()
    else
      %SeoMetadata{product_id: product_id}
      |> SeoMetadata.changeset(allowed)
      |> Repo.insert()
    end
  end


  def set_featured(product_id, featured?) when is_boolean(featured?) do
    product = Repo.get!(Product, product_id)
    Repo.update!(Product.changeset(product, %{featured: featured?}))
    :ok
  end

  def list_featured(limit \\ 10) do
    from(p in Product,
      where: p.featured == true and p.status == :published,
      order_by: [desc: p.updated_at],
      limit: ^limit
    )
    |> Repo.all()
  end


  def add_variant(product_id, attrs) do
    allowed = Map.take(attrs, [:sku, :name, :price_cents, :options, :stock_quantity])

    %ProductVariant{product_id: product_id}
    |> ProductVariant.changeset(allowed)
    |> Repo.insert()
  end

  def update_variant_price(product_id, variant_id, new_price_cents) when new_price_cents > 0 do
    case Repo.get_by(ProductVariant, id: variant_id, product_id: product_id) do
      nil     -> {:error, :not_found}
      variant ->
        Repo.update!(ProductVariant.changeset(variant, %{price_cents: new_price_cents}))
        {:ok, new_price_cents}
    end
  end

  def list_variants(product_id) do
    from(v in ProductVariant,
      where: v.product_id == ^product_id,
      order_by: [asc: v.name]
    )
    |> Repo.all()
  end


  def bulk_import(rows) when is_list(rows) do
    results =
      Enum.map(rows, fn row ->
        attrs = %{
          name:        row["name"],
          sku:         row["sku"],
          description: row["description"],
          price_cents: parse_price(row["price"]),
          status:      :draft
        }

        case create_product(attrs) do
          {:ok, product} -> {:ok, product.id}
          {:error, cs}   -> {:error, {row["sku"], cs.errors}}
        end
      end)

    success = Enum.count(results, &match?({:ok, _}, &1))
    failed  = Enum.filter(results, &match?({:error, _}, &1))

    Logger.info("Bulk import complete: #{success} imported, #{length(failed)} failed")
    %{imported: success, failed: length(failed), errors: failed}
  end

  defp parse_price(nil), do: nil
  defp parse_price(val) when is_integer(val), do: val
  defp parse_price(val) when is_binary(val) do
    val
    |> String.replace(~r/[^0-9.]/, "")
    |> Float.parse()
    |> case do
      {f, _} -> round(f * 100)
      :error -> nil
    end
  end
end
```
