```elixir
defmodule Inventory.ProductCatalog do
  @moduledoc """
  Catalog search and management for the inventory domain.
  Supports filtering, pagination, and aggregate queries over products.
  """

  alias Inventory.Repo
  alias Inventory.Schema.Product
  import Ecto.Query

  @default_page_size 20

  @doc """
  Searches the product catalog with optional filters.

  ## Options

    * `:query` — Substring search on product name or SKU.
    * `:category` — Atom or string category to filter by.
    * `:in_stock` — When `true`, restricts results to products with
      `stock_quantity > 0`.
    * `:count_only` — When `true`, returns just the integer count of
      matching records. Overrides all other options.
    * `:paginate` — When `true`, returns a `%Scrivener.Page{}` struct
      with pagination metadata. Requires `:page` and `:page_size` opts.
    * `:page` — Page number (used with `:paginate`). Defaults to `1`.
    * `:page_size` — Items per page. Defaults to #{@default_page_size}.

  ## Examples

      iex> search(filters)
      [%Product{}, ...]

      iex> search(filters, count_only: true)
      47

      iex> search(filters, paginate: true, page: 2)
      %Scrivener.Page{entries: [%Product{}, ...], total_pages: 3, ...}

  """

  def search(filters \\ [], opts \\ []) when is_list(filters) and is_list(opts) do
    base_query = build_base_query(filters)

    cond do
      opts[:count_only] == true ->
        Repo.aggregate(base_query, :count, :id)

      opts[:paginate] == true ->
        page = Keyword.get(opts, :page, 1)
        page_size = Keyword.get(opts, :page_size, @default_page_size)

        base_query
        |> order_by([p], asc: p.name)
        |> Repo.paginate(page: page, page_size: page_size)

      true ->
        base_query
        |> order_by([p], asc: p.name)
        |> Repo.all()
    end
  end

  defp build_base_query(filters) do
    Enum.reduce(filters, from(p in Product), fn
      {:query, term}, q ->
        like = "%#{term}%"
        where(q, [p], ilike(p.name, ^like) or ilike(p.sku, ^like))

      {:category, cat}, q ->
        where(q, [p], p.category == ^to_string(cat))

      {:in_stock, true}, q ->
        where(q, [p], p.stock_quantity > 0)

      {:price_max, max_price}, q ->
        where(q, [p], p.price <= ^max_price)

      {:price_min, min_price}, q ->
        where(q, [p], p.price >= ^min_price)

      _, q ->
        q
    end)
  end

  @doc """
  Looks up a product by SKU. Returns `{:ok, product}` or `{:error, :not_found}`.
  """
  def get_by_sku(sku) do
    case Repo.get_by(Product, sku: String.upcase(sku)) do
      nil -> {:error, :not_found}
      product -> {:ok, product}
    end
  end

  @doc """
  Updates stock quantity for a product, preventing negative values.
  """
  def adjust_stock(%Product{} = product, delta) when is_integer(delta) do
    new_qty = max(0, product.stock_quantity + delta)

    product
    |> Product.changeset(%{stock_quantity: new_qty})
    |> Repo.update()
  end

  @doc """
  Returns all products below a given restock threshold.
  """
  def low_stock(threshold \\ 5) do
    Product
    |> where([p], p.stock_quantity <= ^threshold and p.active == true)
    |> order_by([p], asc: p.stock_quantity)
    |> Repo.all()
  end

  @doc """
  Deactivates a product, hiding it from the catalog.
  """
  def deactivate(%Product{} = product) do
    product
    |> Product.changeset(%{active: false})
    |> Repo.update()
  end
end
```
