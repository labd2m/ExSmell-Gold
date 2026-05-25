```elixir
defmodule ProductCatalog do
  @moduledoc """
  Manages all product catalog operations including pricing, search, and media.
  """

  require Logger
  import Ecto.Query

  alias MyApp.Repo
  alias MyApp.Catalog.{Product, Category, PricingRule, ProductImage, SearchIndex}
  alias MyApp.Storage

  @max_images_per_product 10
  @default_currency "USD"
  @search_index_name "products"


  def create_product(attrs) do
    with {:ok, product} <-
           %Product{}
           |> Product.changeset(attrs)
           |> Repo.insert() do
      sync_search_index(product)
      Logger.info("Product #{product.id} created: #{product.name}")
      {:ok, product}
    end
  end

  def update_product(product_id, attrs) do
    product = Repo.get!(Product, product_id)

    product
    |> Product.changeset(attrs)
    |> Repo.update()
    |> case do
      {:ok, updated} ->
        sync_search_index(updated)
        {:ok, updated}

      err ->
        err
    end
  end

  def deactivate_product(product_id) do
    Repo.get!(Product, product_id)
    |> Product.changeset(%{active: false, deactivated_at: DateTime.utc_now()})
    |> Repo.update()
    |> case do
      {:ok, updated} ->
        remove_from_search_index(product_id)
        {:ok, updated}

      err ->
        err
    end
  end

  def get_product(product_id) do
    case Repo.get(Product, product_id) do
      nil -> {:error, :not_found}
      product -> {:ok, product}
    end
  end


  def get_effective_price(product_id, %{customer_tier: tier, quantity: qty} = context) do
    product = Repo.get!(Product, product_id)
    rules = fetch_applicable_rules(product_id, context)

    base_price = product.base_price

    final_price =
      Enum.reduce(rules, base_price, fn rule, price ->
        apply_pricing_rule(rule, price, qty)
      end)

    %{
      base: base_price,
      final: final_price,
      discount: Decimal.sub(base_price, final_price),
      currency: @default_currency
    }
  end

  defp fetch_applicable_rules(product_id, %{customer_tier: tier}) do
    Repo.all(
      from r in PricingRule,
        where:
          r.product_id == ^product_id and
            r.active == true and
            (r.customer_tier == ^tier or is_nil(r.customer_tier)),
        order_by: [asc: r.priority]
    )
  end

  defp apply_pricing_rule(%PricingRule{type: :percentage_off, value: pct}, price, _qty) do
    discount = Decimal.mult(price, Decimal.div(pct, Decimal.new(100)))
    Decimal.sub(price, discount)
  end

  defp apply_pricing_rule(%PricingRule{type: :fixed_off, value: amount}, price, _qty) do
    Decimal.sub(price, amount)
  end

  defp apply_pricing_rule(%PricingRule{type: :volume, value: pct, min_quantity: min}, price, qty)
       when qty >= min do
    discount = Decimal.mult(price, Decimal.div(pct, Decimal.new(100)))
    Decimal.sub(price, discount)
  end

  defp apply_pricing_rule(_, price, _), do: price


  def assign_category(product_id, category_id) do
    product = Repo.get!(Product, product_id)
    category = Repo.get!(Category, category_id)

    product
    |> Product.changeset(%{category_id: category.id})
    |> Repo.update()
  end

  def create_category(name, parent_id \\ nil) do
    %Category{name: name, parent_id: parent_id}
    |> Repo.insert()
  end

  def category_tree do
    all = Repo.all(Category)
    roots = Enum.filter(all, &is_nil(&1.parent_id))
    Enum.map(roots, fn root -> build_tree(root, all) end)
  end

  defp build_tree(node, all) do
    children =
      all
      |> Enum.filter(&(&1.parent_id == node.id))
      |> Enum.map(&build_tree(&1, all))

    Map.put(node, :children, children)
  end

  def products_in_category(category_id, include_subcategories \\ false) do
    ids =
      if include_subcategories do
        all = Repo.all(Category)
        descendants(category_id, all)
      else
        [category_id]
      end

    Repo.all(from p in Product, where: p.category_id in ^ids and p.active == true)
  end

  defp descendants(root_id, all) do
    children = Enum.filter(all, &(&1.parent_id == root_id))
    child_ids = Enum.map(children, & &1.id)
    [root_id | Enum.flat_map(child_ids, &descendants(&1, all))]
  end


  def search_products(query, opts \\ []) do
    limit = Keyword.get(opts, :limit, 20)
    category_id = Keyword.get(opts, :category_id)

    base =
      from p in Product,
        where: p.active == true,
        where: ilike(p.name, ^"%#{query}%") or ilike(p.description, ^"%#{query}%"),
        limit: ^limit

    filtered =
      if category_id do
        from p in base, where: p.category_id == ^category_id
      else
        base
      end

    Repo.all(filtered)
  end

  defp sync_search_index(%Product{} = product) do
    doc = %{
      id: product.id,
      name: product.name,
      description: product.description,
      category_id: product.category_id,
      active: product.active,
      indexed_at: DateTime.utc_now()
    }

    case Repo.insert_or_update(SearchIndex.changeset(%SearchIndex{product_id: product.id}, doc)) do
      {:ok, _} -> Logger.debug("Search index synced for product #{product.id}")
      {:error, e} -> Logger.error("Search index sync failed: #{inspect(e)}")
    end
  end

  defp remove_from_search_index(product_id) do
    case Repo.get_by(SearchIndex, product_id: product_id) do
      nil -> :ok
      idx -> Repo.delete(idx)
    end
  end


  def upload_image(product_id, file_path, alt_text \\ "") do
    product = Repo.get!(Product, product_id)
    existing_count = Repo.aggregate(from(i in ProductImage, where: i.product_id == ^product_id), :count)

    if existing_count >= @max_images_per_product do
      {:error, :max_images_reached}
    else
      with {:ok, url} <- Storage.upload(file_path, "products/#{product_id}/"),
           {:ok, image} <-
             Repo.insert(%ProductImage{
               product_id: product.id,
               url: url,
               alt_text: alt_text,
               position: existing_count + 1,
               uploaded_at: DateTime.utc_now()
             }) do
        {:ok, image}
      end
    end
  end

  def reorder_images(product_id, ordered_image_ids) do
    ordered_image_ids
    |> Enum.with_index(1)
    |> Enum.each(fn {image_id, pos} ->
      Repo.get_by!(ProductImage, id: image_id, product_id: product_id)
      |> ProductImage.changeset(%{position: pos})
      |> Repo.update()
    end)

    :ok
  end

  def delete_image(image_id) do
    image = Repo.get!(ProductImage, image_id)
    Storage.delete(image.url)
    Repo.delete(image)
  end
end
```
