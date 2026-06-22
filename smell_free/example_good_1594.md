```elixir
defmodule Catalog.Search do
  @moduledoc """
  Full-text product search backed by PostgreSQL `tsvector` indexes.

  Queries are sanitized and typed before reaching the database layer.
  Facet filters are applied as composable Ecto query fragments.
  """

  import Ecto.Query

  alias Catalog.Repo
  alias Catalog.Search.{Query, Facets, ResultSet}
  alias Catalog.Products.Product

  @max_results 100
  @default_per_page 20

  @type search_opts :: [
          page: pos_integer(),
          per_page: pos_integer(),
          facets: Facets.t()
        ]

  @doc """
  Executes a full-text search and returns a typed `ResultSet`.

  An empty query string returns all products ordered by insertion date.
  """
  @spec search(String.t(), search_opts()) :: {:ok, ResultSet.t()} | {:error, String.t()}
  def search(raw_query, opts \\ []) when is_binary(raw_query) do
    page = Keyword.get(opts, :page, 1)
    per_page = min(Keyword.get(opts, :per_page, @default_per_page), @max_results)
    facets = Keyword.get(opts, :facets, Facets.empty())

    with {:ok, query} <- Query.parse(raw_query) do
      results =
        Product
        |> apply_text_filter(query)
        |> apply_facets(facets)
        |> order_by_relevance(query)
        |> paginate(page, per_page)
        |> Repo.all()

      total = count_matching(raw_query, facets)

      {:ok, ResultSet.new(results, total, page, per_page)}
    end
  end

  @doc """
  Returns aggregated facet counts for a given query without fetching products.
  """
  @spec facet_counts(String.t()) :: {:ok, map()} | {:error, String.t()}
  def facet_counts(raw_query) when is_binary(raw_query) do
    with {:ok, query} <- Query.parse(raw_query) do
      counts =
        Product
        |> apply_text_filter(query)
        |> group_by([p], p.category)
        |> select([p], {p.category, count(p.id)})
        |> Repo.all()
        |> Map.new()

      {:ok, counts}
    end
  end

  # --- composable query builders ---

  defp apply_text_filter(queryable, %Query{terms: []}), do: queryable

  defp apply_text_filter(queryable, %Query{tsquery: tsq}) do
    where(queryable, [p], fragment("? @@ to_tsquery('english', ?)", p.search_vector, ^tsq))
  end

  defp apply_facets(queryable, %Facets{category: nil, min_price: nil, max_price: nil}),
    do: queryable

  defp apply_facets(queryable, %Facets{} = f) do
    queryable
    |> filter_by_category(f.category)
    |> filter_by_price_range(f.min_price, f.max_price)
  end

  defp filter_by_category(q, nil), do: q
  defp filter_by_category(q, cat), do: where(q, [p], p.category == ^cat)

  defp filter_by_price_range(q, nil, nil), do: q
  defp filter_by_price_range(q, min, nil), do: where(q, [p], p.price_cents >= ^min)
  defp filter_by_price_range(q, nil, max), do: where(q, [p], p.price_cents <= ^max)
  defp filter_by_price_range(q, min, max), do: where(q, [p], p.price_cents >= ^min and p.price_cents <= ^max)

  defp order_by_relevance(q, %Query{terms: []}), do: order_by(q, [p], desc: p.inserted_at)

  defp order_by_relevance(q, %Query{tsquery: tsq}) do
    order_by(q, [p], desc: fragment("ts_rank(?, to_tsquery('english', ?))", p.search_vector, ^tsq))
  end

  defp paginate(q, page, per_page) do
    offset = (page - 1) * per_page
    q |> limit(^per_page) |> offset(^offset)
  end

  defp count_matching(raw_query, facets) do
    with {:ok, query} <- Query.parse(raw_query) do
      Product
      |> apply_text_filter(query)
      |> apply_facets(facets)
      |> Repo.aggregate(:count, :id)
    else
      _ -> 0
    end
  end
end
```
