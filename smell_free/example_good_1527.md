```elixir
defmodule Catalog.ProductSearch do
  @moduledoc """
  Composable, filter-driven product search context for the storefront catalog.

  Builds type-safe Ecto queries from structured filter parameters, supporting
  keyword search, category scoping, price ranges, and inventory availability.
  Results are always paginated to prevent unbounded dataset retrieval.
  """

  import Ecto.Query

  alias Catalog.{Product, Repo}

  @type filter_params :: %{
          optional(:keyword) => String.t(),
          optional(:category_id) => pos_integer(),
          optional(:min_price_cents) => non_neg_integer(),
          optional(:max_price_cents) => non_neg_integer(),
          optional(:in_stock_only) => boolean()
        }

  @type pagination :: %{page: pos_integer(), page_size: pos_integer()}

  @type search_result :: %{
          entries: [Product.t()],
          total_count: non_neg_integer(),
          page: pos_integer(),
          page_size: pos_integer()
        }

  @default_page_size 24
  @max_page_size 100

  @doc """
  Executes a filtered, paginated product search.

  Accepts a map of optional filter parameters and pagination controls.
  Always returns a structured result map with entries and metadata.
  """
  @spec search(filter_params(), pagination()) :: search_result()
  def search(filters, pagination \\ %{}) do
    page = max(Map.get(pagination, :page, 1), 1)
    page_size = resolve_page_size(Map.get(pagination, :page_size, @default_page_size))
    offset = (page - 1) * page_size

    base_query = from(p in Product, where: p.active == true)

    filtered_query =
      base_query
      |> apply_keyword_filter(Map.get(filters, :keyword))
      |> apply_category_filter(Map.get(filters, :category_id))
      |> apply_min_price_filter(Map.get(filters, :min_price_cents))
      |> apply_max_price_filter(Map.get(filters, :max_price_cents))
      |> apply_stock_filter(Map.get(filters, :in_stock_only))

    total_count = Repo.aggregate(filtered_query, :count, :id)

    entries =
      filtered_query
      |> order_by([p], [asc: p.name])
      |> limit(^page_size)
      |> offset(^offset)
      |> Repo.all()

    %{
      entries: entries,
      total_count: total_count,
      page: page,
      page_size: page_size
    }
  end

  defp resolve_page_size(requested) when requested > @max_page_size, do: @max_page_size
  defp resolve_page_size(requested) when requested < 1, do: @default_page_size
  defp resolve_page_size(requested), do: requested

  defp apply_keyword_filter(query, nil), do: query
  defp apply_keyword_filter(query, ""), do: query

  defp apply_keyword_filter(query, keyword) do
    pattern = "%#{keyword}%"
    from(p in query, where: ilike(p.name, ^pattern) or ilike(p.description, ^pattern))
  end

  defp apply_category_filter(query, nil), do: query

  defp apply_category_filter(query, category_id) do
    from(p in query, where: p.category_id == ^category_id)
  end

  defp apply_min_price_filter(query, nil), do: query

  defp apply_min_price_filter(query, min_cents) do
    from(p in query, where: p.price_cents >= ^min_cents)
  end

  defp apply_max_price_filter(query, nil), do: query

  defp apply_max_price_filter(query, max_cents) do
    from(p in query, where: p.price_cents <= ^max_cents)
  end

  defp apply_stock_filter(query, true) do
    from(p in query, where: p.stock_quantity > 0)
  end

  defp apply_stock_filter(query, _), do: query
end
```
