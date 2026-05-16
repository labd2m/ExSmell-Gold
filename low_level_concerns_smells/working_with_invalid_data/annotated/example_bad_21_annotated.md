# Code Smell Annotation

- **Smell name:** Working with invalid data
- **Expected smell location:** `ProductSearch.search/2`, where `page` is used in `offset` arithmetic
- **Affected function(s):** `search/2`
- **Short explanation:** The `page` parameter is extracted from the search options and used directly in the arithmetic expression `(page - 1) * per_page` without validating that it is a positive integer. If a caller passes a string `"2"` (as often happens when forwarding raw HTTP query parameters), the subtraction raises an `ArithmeticError` deep in the offset computation, completely hiding the fact that the invalid data entered at the `search/2` boundary.

```elixir
defmodule MyApp.Catalog.ProductSearch do
  @moduledoc """
  Full-text and faceted product search over the catalog, supporting
  keyword queries, category filters, price ranges, and paginated results.
  """

  require Logger

  alias MyApp.Catalog.{SearchIndex, ProductRecord, FacetBuilder}

  @default_per_page 24
  @max_per_page 100
  @default_sort :relevance
  @supported_sorts [:relevance, :price_asc, :price_desc, :newest, :rating]

  @type search_opts :: [
          page: pos_integer(),
          per_page: pos_integer(),
          sort: atom(),
          category_ids: [String.t()],
          price_min: number() | nil,
          price_max: number() | nil,
          in_stock_only: boolean(),
          include_facets: boolean()
        ]

  @spec search(String.t() | nil, search_opts()) ::
          {:ok, map()} | {:error, atom()}
  def search(query, opts \\ []) do
    per_page = min(Keyword.get(opts, :per_page, @default_per_page), @max_per_page)
    sort = Keyword.get(opts, :sort, @default_sort)
    category_ids = Keyword.get(opts, :category_ids, [])
    price_min = Keyword.get(opts, :price_min)
    price_max = Keyword.get(opts, :price_max)
    in_stock_only = Keyword.get(opts, :in_stock_only, false)
    include_facets = Keyword.get(opts, :include_facets, false)

    page = Keyword.get(opts, :page, 1)

    with :ok <- validate_sort(sort),
         :ok <- validate_price_range(price_min, price_max) do

      # VALIDATION: SMELL START - Working with invalid data
      # VALIDATION: This is a smell because `page` is used in arithmetic to
      # VALIDATION: compute the `offset` without checking it is an integer.
      # VALIDATION: In web controllers it is common to pass query parameters
      # VALIDATION: directly: `params["page"]` returns a string like "2".
      # VALIDATION: The subtraction `page - 1` will raise an ArithmeticError
      # VALIDATION: inside the Elixir runtime, far from the entry point.
      offset = (page - 1) * per_page
      # VALIDATION: SMELL END

      filters = %{
        category_ids: category_ids,
        price_min: price_min,
        price_max: price_max,
        in_stock_only: in_stock_only
      }

      with {:ok, hits, total} <- SearchIndex.query(query, filters, sort, offset, per_page),
           {:ok, product_ids} <- extract_ids(hits),
           {:ok, products} <- ProductRecord.fetch_many(product_ids) do
        result = %{
          query: query,
          products: products,
          page: page,
          per_page: per_page,
          total: total,
          total_pages: ceil(total / per_page),
          has_next: offset + per_page < total,
          has_prev: page > 1
        }

        result =
          if include_facets do
            case FacetBuilder.build(query, filters) do
              {:ok, facets} -> Map.put(result, :facets, facets)
              _ -> result
            end
          else
            result
          end

        Logger.debug("Search: query=#{inspect(query)} page=#{page} total=#{total}")
        {:ok, result}
      end
    end
  end

  @spec suggestions(String.t(), pos_integer()) :: {:ok, [String.t()]} | {:error, atom()}
  def suggestions(partial_query, limit \\ 5) do
    SearchIndex.autocomplete(partial_query, limit)
  end

  @spec similar_products(String.t(), pos_integer()) ::
          {:ok, [ProductRecord.t()]} | {:error, atom()}
  def similar_products(product_id, limit \\ 6) do
    with {:ok, product} <- ProductRecord.fetch(product_id),
         {:ok, ids} <- SearchIndex.more_like_this(product_id, product.category_id, limit),
         {:ok, products} <- ProductRecord.fetch_many(ids) do
      {:ok, products}
    end
  end

  @spec index_product(ProductRecord.t()) :: :ok | {:error, atom()}
  def index_product(product) do
    SearchIndex.upsert(product.id, %{
      name: product.name,
      description: product.description,
      category_ids: product.category_ids,
      price: product.price,
      stock_qty: product.stock_qty,
      rating: product.rating,
      tags: product.tags
    })
  end

  # Private helpers

  defp validate_sort(sort) when sort in @supported_sorts, do: :ok
  defp validate_sort(_), do: {:error, :invalid_sort}

  defp validate_price_range(nil, _), do: :ok
  defp validate_price_range(_, nil), do: :ok
  defp validate_price_range(min, max) when min <= max, do: :ok
  defp validate_price_range(_, _), do: {:error, :invalid_price_range}

  defp extract_ids(hits) do
    {:ok, Enum.map(hits, & &1.product_id)}
  end
end
```
