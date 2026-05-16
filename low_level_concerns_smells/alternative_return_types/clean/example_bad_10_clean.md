```elixir
defmodule MyApp.Catalog.Product do
  @moduledoc """
  Product catalog search and filtering. Supports full-text search, faceted
  filtering, and pagination for storefront and admin interfaces.
  """

  alias MyApp.Repo
  alias MyApp.Catalog.SearchIndex
  alias MyApp.Catalog.Category

  defstruct [
    :id, :sku, :name, :description,
    :price, :currency, :category_id,
    :tags, :active, :stock_qty,
    :inserted_at
  ]

  @default_page_size 20
  @max_page_size 100

  def changeset(attrs) do
    %__MODULE__{
      id: attrs[:id] || generate_id(),
      sku: attrs[:sku],
      name: attrs[:name],
      description: attrs[:description],
      price: attrs[:price],
      currency: attrs[:currency] || "BRL",
      category_id: attrs[:category_id],
      tags: attrs[:tags] || [],
      active: Map.get(attrs, :active, true),
      stock_qty: attrs[:stock_qty] || 0,
      inserted_at: DateTime.utc_now()
    }
  end

  def search(query_string, opts \\ []) when is_list(opts) do
    wrap = Keyword.get(opts, :wrap, :none)
    page = Keyword.get(opts, :page, 1)
    page_size = min(Keyword.get(opts, :page_size, @default_page_size), @max_page_size)
    category_id = Keyword.get(opts, :category_id)
    min_price = Keyword.get(opts, :min_price)
    max_price = Keyword.get(opts, :max_price)
    only_active = Keyword.get(opts, :only_active, true)
    sort_by = Keyword.get(opts, :sort_by, :relevance)

    base =
      SearchIndex.query(query_string)
      |> then(fn q -> if only_active, do: SearchIndex.filter_active(q), else: q end)
      |> then(fn q ->
        if category_id, do: SearchIndex.filter_category(q, category_id), else: q
      end)
      |> then(fn q ->
        if min_price, do: SearchIndex.filter_min_price(q, min_price), else: q
      end)
      |> then(fn q ->
        if max_price, do: SearchIndex.filter_max_price(q, max_price), else: q
      end)
      |> SearchIndex.sort(sort_by)

    case wrap do
      :none ->
        Repo.all(base)

      :page ->
        total_count = Repo.aggregate(base, :count, :id)
        total_pages = ceil(total_count / page_size)
        offset = (page - 1) * page_size

        results =
          base
          |> SearchIndex.paginate(offset, page_size)
          |> Repo.all()

        meta = %{
          page: page,
          page_size: page_size,
          total_count: total_count,
          total_pages: total_pages,
          has_next: page < total_pages,
          has_prev: page > 1
        }

        {results, meta}

      :count ->
        Repo.aggregate(base, :count, :id)
    end
  end
  
  def by_category(category_id) do
    Category
    |> Category.with_products(category_id)
    |> Repo.all()
  end

  def deactivate(product_id) do
    with {:ok, product} <- Repo.fetch(__MODULE__, product_id) do
      Repo.update(%{product | active: false})
    end
  end

  def update_price(product_id, new_price, currency \\ "BRL") do
    with {:ok, product} <- Repo.fetch(__MODULE__, product_id) do
      Repo.update(%{product | price: new_price, currency: currency})
    end
  end

  defp generate_id do
    :crypto.strong_rand_bytes(12) |> Base.encode16(case: :lower)
  end
end
```
