```elixir
defmodule Catalog.FilterParams do
  @moduledoc """
  Strongly typed parameters for product catalog filtering and sorting.
  Callers construct this struct to drive `Catalog.list_products/1`.
  """

  @type sort_field :: :name | :price_cents | :inserted_at
  @type sort_direction :: :asc | :desc

  @type t :: %__MODULE__{
          query: String.t() | nil,
          category_ids: [Ecto.UUID.t()],
          min_price_cents: non_neg_integer() | nil,
          max_price_cents: non_neg_integer() | nil,
          in_stock_only: boolean(),
          sort_by: sort_field(),
          sort_dir: sort_direction(),
          limit: pos_integer(),
          offset: non_neg_integer()
        }

  defstruct [
    query: nil,
    category_ids: [],
    min_price_cents: nil,
    max_price_cents: nil,
    in_stock_only: false,
    sort_by: :inserted_at,
    sort_dir: :desc,
    limit: 24,
    offset: 0
  ]
end

defmodule Catalog do
  import Ecto.Query

  alias Catalog.FilterParams
  alias MyApp.Repo
  alias MyApp.Schemas.Product

  @moduledoc """
  Context for browsing and searching the product catalog.
  Provides composable, type-safe filtering over the products table.
  """

  @spec list_products(FilterParams.t()) :: [Product.t()]
  def list_products(%FilterParams{} = params) do
    Product
    |> apply_text_search(params.query)
    |> apply_category_filter(params.category_ids)
    |> apply_price_range(params.min_price_cents, params.max_price_cents)
    |> apply_stock_filter(params.in_stock_only)
    |> apply_sorting(params.sort_by, params.sort_dir)
    |> limit(^params.limit)
    |> offset(^params.offset)
    |> Repo.all()
  end

  @spec count_products(FilterParams.t()) :: non_neg_integer()
  def count_products(%FilterParams{} = params) do
    Product
    |> apply_text_search(params.query)
    |> apply_category_filter(params.category_ids)
    |> apply_price_range(params.min_price_cents, params.max_price_cents)
    |> apply_stock_filter(params.in_stock_only)
    |> select(count())
    |> Repo.one()
  end

  defp apply_text_search(query, nil), do: query
  defp apply_text_search(query, ""), do: query

  defp apply_text_search(query, search_term) when is_binary(search_term) do
    term = "%#{search_term}%"
    where(query, [p], ilike(p.name, ^term) or ilike(p.description, ^term))
  end

  defp apply_category_filter(query, []), do: query

  defp apply_category_filter(query, category_ids) when is_list(category_ids) do
    where(query, [p], p.category_id in ^category_ids)
  end

  defp apply_price_range(query, nil, nil), do: query

  defp apply_price_range(query, min, nil) when is_integer(min) do
    where(query, [p], p.price_cents >= ^min)
  end

  defp apply_price_range(query, nil, max) when is_integer(max) do
    where(query, [p], p.price_cents <= ^max)
  end

  defp apply_price_range(query, min, max) when is_integer(min) and is_integer(max) do
    where(query, [p], p.price_cents >= ^min and p.price_cents <= ^max)
  end

  defp apply_stock_filter(query, false), do: query

  defp apply_stock_filter(query, true) do
    where(query, [p], p.stock_quantity > 0)
  end

  defp apply_sorting(query, field, direction) do
    order_by(query, [p], [{^direction, field(p, ^field)}])
  end
end
```
