```elixir
defmodule Shop.ProductCatalog do
  @moduledoc """
  Handles product catalog entries, pricing configuration, and stock tracking.
  """

  alias Shop.Repo
  alias Shop.Products.Product
  alias Shop.Products.PriceRule
  alias Shop.Inventory.StockEntry

  import Ecto.Query
  require Logger



  @doc "Creates a new product entry in the catalog."
  @spec create_product(map()) :: {:ok, Product.t()} | {:error, Ecto.Changeset.t()}
  def create_product(attrs) do
    %Product{}
    |> Product.changeset(Map.put(attrs, :status, :draft))
    |> Repo.insert()
  end

  @doc "Updates mutable product fields such as name, description, or category."
  @spec update_product(Product.t(), map()) :: {:ok, Product.t()} | {:error, Ecto.Changeset.t()}
  def update_product(%Product{} = product, attrs) do
    product
    |> Product.changeset(attrs)
    |> Repo.update()
  end

  @doc "Archives a product, hiding it from storefronts without deleting data."
  @spec archive_product(Product.t()) :: {:ok, Product.t()} | {:error, Ecto.Changeset.t()}
  def archive_product(%Product{} = product) do
    product
    |> Product.changeset(%{status: :archived, archived_at: DateTime.utc_now()})
    |> Repo.update()
  end

  @doc "Lists products with optional filtering by category, status, or keyword."
  @spec list_products(map()) :: [Product.t()]
  def list_products(filters \\ %{}) do
    base = from(p in Product, where: p.status != :archived)

    base
    |> maybe_filter_by_category(filters[:category_id])
    |> maybe_filter_by_status(filters[:status])
    |> maybe_search(filters[:search])
    |> order_by([p], asc: p.name)
    |> Repo.all()
  end


  @doc "Sets the base price for a product."
  @spec set_price(Product.t(), pos_integer()) ::
          {:ok, Product.t()} | {:error, Ecto.Changeset.t()}
  def set_price(%Product{} = product, price_cents) when price_cents > 0 do
    product
    |> Product.changeset(%{base_price_cents: price_cents})
    |> Repo.update()
  end

  @doc "Applies a bulk (tiered) discount rule for volume purchases."
  @spec apply_bulk_discount(Product.t(), map()) ::
          {:ok, PriceRule.t()} | {:error, Ecto.Changeset.t()}
  def apply_bulk_discount(%Product{id: product_id}, %{min_quantity: min_qty, discount_pct: pct}) do
    attrs = %{
      product_id: product_id,
      rule_type: :bulk,
      min_quantity: min_qty,
      discount_percent: pct,
      active: true
    }

    %PriceRule{} |> PriceRule.changeset(attrs) |> Repo.insert()
  end

  @doc "Calculates the effective price for a product, applying any active discount rules."
  @spec get_effective_price(Product.t(), pos_integer()) :: pos_integer()
  def get_effective_price(%Product{id: pid, base_price_cents: base}, quantity) do
    rule =
      PriceRule
      |> where([r], r.product_id == ^pid and r.active == true and r.min_quantity <= ^quantity)
      |> order_by([r], desc: r.min_quantity)
      |> limit(1)
      |> Repo.one()

    case rule do
      nil ->
        base

      %PriceRule{discount_percent: pct} ->
        discounted = base - round(base * pct / 100)
        Logger.debug("Applied bulk discount #{pct}% to product #{pid}")
        discounted
    end
  end


  @doc "Increments stock for a product (e.g. after receiving a shipment)."
  @spec increment_stock(Product.t(), pos_integer()) ::
          {:ok, StockEntry.t()} | {:error, term()}
  def increment_stock(%Product{id: pid}, quantity) when is_integer(quantity) and quantity > 0 do
    entry = Repo.get_by(StockEntry, product_id: pid) || %StockEntry{product_id: pid}
    new_qty = (entry.quantity || 0) + quantity

    entry
    |> StockEntry.changeset(%{quantity: new_qty, last_restocked_at: DateTime.utc_now()})
    |> Repo.insert_or_update()
  end

  @doc "Decrements stock for a product, refusing if insufficient units are available."
  @spec decrement_stock(Product.t(), pos_integer()) :: :ok | {:error, atom()}
  def decrement_stock(%Product{id: pid}, quantity) do
    case Repo.get_by(StockEntry, product_id: pid) do
      nil ->
        {:error, :no_stock_record}

      %StockEntry{quantity: current} when current < quantity ->
        {:error, :insufficient_stock}

      %StockEntry{} = entry ->
        entry
        |> StockEntry.changeset(%{quantity: entry.quantity - quantity})
        |> Repo.update()

        :ok
    end
  end

  @doc "Returns current on-hand quantity for a product."
  @spec get_stock_level(Product.t()) :: non_neg_integer()
  def get_stock_level(%Product{id: pid}) do
    StockEntry
    |> where([s], s.product_id == ^pid)
    |> select([s], s.quantity)
    |> Repo.one()
    |> Kernel.||(0)
  end


  defp maybe_filter_by_category(query, nil), do: query

  defp maybe_filter_by_category(query, category_id),
    do: where(query, [p], p.category_id == ^category_id)

  defp maybe_filter_by_status(query, nil), do: query
  defp maybe_filter_by_status(query, status), do: where(query, [p], p.status == ^status)

  defp maybe_search(query, nil), do: query

  defp maybe_search(query, term),
    do: where(query, [p], ilike(p.name, ^"%#{term}%") or ilike(p.description, ^"%#{term}%"))

end
```
