# File: `example_good_08.md`

```elixir
defmodule Catalog.ProductSearch do
  @moduledoc """
  Provides faceted search over the product catalog backed by Ecto
  and PostgreSQL full-text search.

  All query parameters are typed and validated at the boundary so that
  invalid inputs produce descriptive errors rather than database exceptions.
  """

  import Ecto.Query, warn: false

  alias Catalog.Repo
  alias Catalog.Products.Product

  @type search_params :: %{
          optional(:query) => String.t(),
          optional(:category_id) => pos_integer(),
          optional(:min_price_cents) => non_neg_integer(),
          optional(:max_price_cents) => non_neg_integer(),
          optional(:in_stock_only) => boolean(),
          optional(:sort_by) => :price_asc | :price_desc | :newest | :relevance
        }

  @type paginated_result :: %{
          items: [Product.t()],
          total_count: non_neg_integer(),
          page: pos_integer(),
          per_page: pos_integer()
        }

  @allowed_sort_fields [:price_asc, :price_desc, :newest, :relevance]

  @doc """
  Searches the product catalog using the given parameters, returning
  a paginated result set.

  Parameters:
  - `:query` — full-text search string
  - `:category_id` — filter to a specific category
  - `:min_price_cents` / `:max_price_cents` — price range filters
  - `:in_stock_only` — exclude products with zero inventory
  - `:sort_by` — one of `:price_asc`, `:price_desc`, `:newest`, `:relevance`

  Returns `{:ok, paginated_result}` or `{:error, :invalid_params}`.
  """
  @spec search(search_params(), pos_integer(), pos_integer()) ::
          {:ok, paginated_result()} | {:error, :invalid_params}
  def search(params, page \\ 1, per_page \\ 20)
      when is_map(params) and is_integer(page) and page > 0 and
             is_integer(per_page) and per_page > 0 do
    case validate_params(params) do
      {:ok, validated} -> execute_search(validated, page, per_page)
      {:error, _} = error -> error
    end
  end

  defp validate_params(params) do
    with :ok <- validate_sort(params),
         :ok <- validate_price_range(params) do
      {:ok, params}
    end
  end

  defp validate_sort(%{sort_by: sort}) when sort not in @allowed_sort_fields do
    {:error, :invalid_params}
  end

  defp validate_sort(_params), do: :ok

  defp validate_price_range(%{min_price_cents: min, max_price_cents: max})
       when is_integer(min) and is_integer(max) and min > max do
    {:error, :invalid_params}
  end

  defp validate_price_range(_params), do: :ok

  defp execute_search(params, page, per_page) do
    base_query =
      Product
      |> apply_text_filter(params)
      |> apply_category_filter(params)
      |> apply_price_range(params)
      |> apply_stock_filter(params)

    total_count = Repo.aggregate(base_query, :count, :id)

    items =
      base_query
      |> apply_sort(params)
      |> apply_pagination(page, per_page)
      |> Repo.all()

    {:ok, %{items: items, total_count: total_count, page: page, per_page: per_page}}
  end

  defp apply_text_filter(query, %{query: text}) when is_binary(text) and byte_size(text) > 0 do
    search_term = "%#{sanitize_search_term(text)}%"
    where(query, [p], ilike(p.name, ^search_term) or ilike(p.description, ^search_term))
  end

  defp apply_text_filter(query, _params), do: query

  defp apply_category_filter(query, %{category_id: id}) when is_integer(id) and id > 0 do
    where(query, [p], p.category_id == ^id)
  end

  defp apply_category_filter(query, _params), do: query

  defp apply_price_range(query, params) do
    query
    |> maybe_apply_min_price(params)
    |> maybe_apply_max_price(params)
  end

  defp maybe_apply_min_price(query, %{min_price_cents: min}) when is_integer(min) and min >= 0 do
    where(query, [p], p.price_cents >= ^min)
  end

  defp maybe_apply_min_price(query, _params), do: query

  defp maybe_apply_max_price(query, %{max_price_cents: max}) when is_integer(max) and max > 0 do
    where(query, [p], p.price_cents <= ^max)
  end

  defp maybe_apply_max_price(query, _params), do: query

  defp apply_stock_filter(query, %{in_stock_only: true}) do
    where(query, [p], p.inventory_count > 0)
  end

  defp apply_stock_filter(query, _params), do: query

  defp apply_sort(query, %{sort_by: :price_asc}), do: order_by(query, [p], asc: p.price_cents)
  defp apply_sort(query, %{sort_by: :price_desc}), do: order_by(query, [p], desc: p.price_cents)
  defp apply_sort(query, %{sort_by: :newest}), do: order_by(query, [p], desc: p.inserted_at)
  defp apply_sort(query, _params), do: order_by(query, [p], desc: p.inserted_at)

  defp apply_pagination(query, page, per_page) do
    query
    |> limit(^per_page)
    |> offset(^((page - 1) * per_page))
  end

  defp sanitize_search_term(text) do
    String.replace(text, ~r/[%_\\]/, "")
  end
end
```
