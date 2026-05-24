# Annotated Example — Code Smell Validation

## Metadata

- **Smell name:** Divergent Change
- **Expected smell location:** The entire `ProductCatalog` module
- **Affected function(s):** `create_product/1`, `update_product/2`, `archive_product/1`, `set_price/3`, `apply_bulk_discount/3`, `get_effective_price/2`, `assign_category/2`, `create_category/2`, `category_tree/0`
- **Short explanation:** The `ProductCatalog` module bundles three distinct concerns: product CRUD (what products exist and their attributes), dynamic pricing/discounting logic (how products are priced), and category taxonomy management (how products are organised). Regulatory changes to product data, a new discounting strategy, and a re-organisation of the category hierarchy are completely independent reasons to change this single module.

---

```elixir
defmodule MyApp.ProductCatalog do
  @moduledoc """
  Manages the product catalogue: product lifecycle, pricing rules,
  and the category taxonomy used for navigation and reporting.
  """

  alias MyApp.Repo
  alias MyApp.Catalog.{Product, Price, Category}
  import Ecto.Query

  # VALIDATION: SMELL START - Divergent Change
  # VALIDATION: This is a smell because the module conflates three unrelated domains.
  # VALIDATION: Product CRUD changes when attribute schemas or validation rules change.
  # VALIDATION: Pricing functions change when discount models, promotions, or currency
  # VALIDATION: handling requirements change. Category functions change when the
  # VALIDATION: taxonomy depth, slug rules, or display hierarchy changes. Each axis
  # VALIDATION: is a distinct reason to modify the module.

  # ── Reason to modify (1): Product lifecycle (CRUD) ─────────────────────────

  @required_attrs [:sku, :name, :weight_grams, :supplier_id]

  def create_product(attrs) do
    with :ok <- validate_required(attrs, @required_attrs),
         :ok <- validate_unique_sku(attrs[:sku]) do
      %Product{}
      |> Product.changeset(Map.put(attrs, :status, :active))
      |> Repo.insert()
    end
  end

  def update_product(product_id, attrs) do
    forbidden = [:sku, :supplier_id]
    safe_attrs = Map.drop(attrs, forbidden)

    product_id
    |> get_active_product!()
    |> Product.changeset(safe_attrs)
    |> Repo.update()
  end

  def archive_product(product_id) do
    product_id
    |> get_active_product!()
    |> Product.changeset(%{status: :archived, archived_at: DateTime.utc_now()})
    |> Repo.update()
  end

  defp get_active_product!(product_id) do
    case Repo.get_by(Product, id: product_id, status: :active) do
      nil -> raise Ecto.NoResultsError, queryable: Product
      product -> product
    end
  end

  defp validate_required(attrs, fields) do
    missing = Enum.filter(fields, &is_nil(Map.get(attrs, &1)))

    if missing == [] do
      :ok
    else
      {:error, {:missing_fields, missing}}
    end
  end

  defp validate_unique_sku(sku) do
    if Repo.exists?(from p in Product, where: p.sku == ^sku) do
      {:error, :sku_already_exists}
    else
      :ok
    end
  end

  # ── Reason to modify (2): Pricing & discount rules ─────────────────────────

  def set_price(product_id, amount_cents, currency \\ "USD") do
    existing = Repo.get_by(Price, product_id: product_id, currency: currency, active: true)

    if existing do
      existing |> Price.changeset(%{active: false}) |> Repo.update!()
    end

    %Price{}
    |> Price.changeset(%{
      product_id: product_id,
      amount_cents: amount_cents,
      currency: currency,
      active: true,
      effective_from: DateTime.utc_now()
    })
    |> Repo.insert()
  end

  def apply_bulk_discount(product_id, min_quantity, discount_percent)
      when discount_percent > 0 and discount_percent < 100 do
    product = get_active_product!(product_id)

    existing_tiers = product.bulk_discount_tiers || []

    new_tier = %{min_qty: min_quantity, discount_pct: discount_percent}

    updated_tiers =
      existing_tiers
      |> Enum.reject(&(&1.min_qty == min_quantity))
      |> then(&[new_tier | &1])
      |> Enum.sort_by(& &1.min_qty)

    product
    |> Product.changeset(%{bulk_discount_tiers: updated_tiers})
    |> Repo.update()
  end

  def get_effective_price(product_id, quantity, currency \\ "USD") do
    price =
      from(p in Price,
        where: p.product_id == ^product_id and p.currency == ^currency and p.active == true,
        order_by: [desc: p.effective_from],
        limit: 1
      )
      |> Repo.one()

    if is_nil(price) do
      {:error, :no_price_set}
    else
      product = get_active_product!(product_id)

      discount =
        (product.bulk_discount_tiers || [])
        |> Enum.filter(&(&1.min_qty <= quantity))
        |> Enum.max_by(& &1.discount_pct, fn -> %{discount_pct: 0} end)
        |> Map.get(:discount_pct)

      unit_price = round(price.amount_cents * (1 - discount / 100))
      {:ok, %{unit_price_cents: unit_price, discount_pct: discount, currency: currency}}
    end
  end

  # ── Reason to modify (3): Category taxonomy management ─────────────────────

  def create_category(name, parent_id \\ nil) do
    slug = slugify(name)

    if Repo.exists?(from c in Category, where: c.slug == ^slug) do
      {:error, :slug_conflict}
    else
      %Category{}
      |> Category.changeset(%{name: name, slug: slug, parent_id: parent_id})
      |> Repo.insert()
    end
  end

  def assign_category(product_id, category_id) do
    product = get_active_product!(product_id)
    _category = Repo.get!(Category, category_id)

    product
    |> Product.changeset(%{category_id: category_id})
    |> Repo.update()
  end

  def category_tree do
    all = Repo.all(Category)
    roots = Enum.filter(all, &is_nil(&1.parent_id))
    build_tree(roots, all)
  end

  defp build_tree(nodes, all) do
    Enum.map(nodes, fn node ->
      children = Enum.filter(all, &(&1.parent_id == node.id))
      Map.put(node, :children, build_tree(children, all))
    end)
  end

  defp slugify(name) do
    name
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "-")
    |> String.trim("-")
  end

  # VALIDATION: SMELL END
end
```
