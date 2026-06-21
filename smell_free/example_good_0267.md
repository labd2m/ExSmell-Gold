```elixir
defmodule Catalog.ProductSearch do
  @moduledoc """
  Builds composable Ecto queries for full-text and faceted product search.
  Each filter function is a pure query transformer, making the pipeline
  easy to extend without touching existing clauses.
  All monetary filter values are expressed in cents.
  """

  alias Catalog.{Product, Repo}
  import Ecto.Query

  @type filter_opts :: [
          keyword: String.t() | nil,
          category_ids: [binary()],
          min_price_cents: non_neg_integer() | nil,
          max_price_cents: non_neg_integer() | nil,
          in_stock: boolean() | nil,
          tags: [String.t()],
          sort: :relevance | :price_asc | :price_desc | :newest,
          page: pos_integer(),
          per_page: pos_integer()
        ]

  @type search_result :: %{
          items: [Product.t()],
          total_count: non_neg_integer(),
          page: pos_integer(),
          total_pages: non_neg_integer()
        }

  @doc """
  Executes a paginated product search with the given filters.
  Returns a result map containing items and pagination metadata.
  """
  @spec search(filter_opts()) :: search_result()
  def search(opts \\ []) do
    page = Keyword.get(opts, :page, 1)
    per_page = Keyword.get(opts, :per_page, 24)

    base_query = from(p in Product, where: p.published == true)

    filtered =
      base_query
      |> apply_keyword_filter(Keyword.get(opts, :keyword))
      |> apply_category_filter(Keyword.get(opts, :category_ids, []))
      |> apply_price_filter(Keyword.get(opts, :min_price_cents), Keyword.get(opts, :max_price_cents))
      |> apply_stock_filter(Keyword.get(opts, :in_stock))
      |> apply_tag_filter(Keyword.get(opts, :tags, []))

    total_count = Repo.aggregate(filtered, :count, :id)

    items =
      filtered
      |> apply_sort(Keyword.get(opts, :sort, :newest))
      |> paginate(page, per_page)
      |> Repo.all()

    %{
      items: items,
      total_count: total_count,
      page: page,
      total_pages: ceil_div(total_count, per_page)
    }
  end

  # ---------------------------------------------------------------------------
  # Filter transformers
  # ---------------------------------------------------------------------------

  defp apply_keyword_filter(query, nil), do: query
  defp apply_keyword_filter(query, ""), do: query

  defp apply_keyword_filter(query, keyword) when is_binary(keyword) do
    term = "%#{sanitize_like(keyword)}%"

    where(
      query,
      [p],
      ilike(p.name, ^term) or ilike(p.description, ^term) or ilike(p.sku, ^term)
    )
  end

  defp apply_category_filter(query, []), do: query

  defp apply_category_filter(query, category_ids) when is_list(category_ids) do
    where(query, [p], p.category_id in ^category_ids)
  end

  defp apply_price_filter(query, nil, nil), do: query

  defp apply_price_filter(query, min, nil) when is_integer(min) do
    where(query, [p], p.price_cents >= ^min)
  end

  defp apply_price_filter(query, nil, max) when is_integer(max) do
    where(query, [p], p.price_cents <= ^max)
  end

  defp apply_price_filter(query, min, max) when is_integer(min) and is_integer(max) do
    where(query, [p], p.price_cents >= ^min and p.price_cents <= ^max)
  end

  defp apply_stock_filter(query, nil), do: query
  defp apply_stock_filter(query, true), do: where(query, [p], p.stock_quantity > 0)
  defp apply_stock_filter(query, false), do: where(query, [p], p.stock_quantity == 0)

  defp apply_tag_filter(query, []), do: query

  defp apply_tag_filter(query, tags) when is_list(tags) do
    where(query, [p], fragment("? @> ?::text[]", p.tags, ^tags))
  end

  defp apply_sort(query, :price_asc), do: order_by(query, [p], asc: p.price_cents)
  defp apply_sort(query, :price_desc), do: order_by(query, [p], desc: p.price_cents)
  defp apply_sort(query, :newest), do: order_by(query, [p], desc: p.inserted_at)
  defp apply_sort(query, :relevance), do: query

  defp paginate(query, page, per_page) do
    query
    |> limit(^per_page)
    |> offset(^((page - 1) * per_page))
  end

  defp sanitize_like(term), do: String.replace(term, ~r/[%_\\]/, "\\\\\\0")

  defp ceil_div(_total, 0), do: 1
  defp ceil_div(total, per_page), do: ceil(total / per_page)
end
```
