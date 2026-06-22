```elixir
defmodule Catalog.ProductSearch do
  @moduledoc """
  Provides full-text and filtered search over the product catalog.
  All query composition is handled through composable Ecto query functions.
  """

  import Ecto.Query

  alias Catalog.{Product, Repo}

  @type search_opts :: [
          query: String.t(),
          category_id: pos_integer(),
          min_price: non_neg_integer(),
          max_price: non_neg_integer(),
          in_stock: boolean(),
          page: pos_integer(),
          per_page: pos_integer()
        ]

  @default_page 1
  @default_per_page 20

  @spec search(search_opts()) :: {:ok, %{results: [Product.t()], total: non_neg_integer()}}
  def search(opts \\ []) do
    page = Keyword.get(opts, :page, @default_page)
    per_page = Keyword.get(opts, :per_page, @default_per_page)
    offset = (page - 1) * per_page

    base = from(p in Product, where: p.active == true)

    query =
      base
      |> apply_text_filter(Keyword.get(opts, :query))
      |> apply_category_filter(Keyword.get(opts, :category_id))
      |> apply_price_range(Keyword.get(opts, :min_price), Keyword.get(opts, :max_price))
      |> apply_stock_filter(Keyword.get(opts, :in_stock))

    total = Repo.aggregate(query, :count, :id)

    results =
      query
      |> order_by([p], asc: p.name)
      |> limit(^per_page)
      |> offset(^offset)
      |> Repo.all()

    {:ok, %{results: results, total: total}}
  end

  @spec apply_text_filter(Ecto.Query.t(), String.t() | nil) :: Ecto.Query.t()
  defp apply_text_filter(query, nil), do: query
  defp apply_text_filter(query, ""), do: query

  defp apply_text_filter(query, text) do
    pattern = "%#{text}%"
    from(p in query, where: ilike(p.name, ^pattern) or ilike(p.description, ^pattern))
  end

  @spec apply_category_filter(Ecto.Query.t(), pos_integer() | nil) :: Ecto.Query.t()
  defp apply_category_filter(query, nil), do: query

  defp apply_category_filter(query, category_id) do
    from(p in query, where: p.category_id == ^category_id)
  end

  @spec apply_price_range(Ecto.Query.t(), non_neg_integer() | nil, non_neg_integer() | nil) ::
          Ecto.Query.t()
  defp apply_price_range(query, nil, nil), do: query

  defp apply_price_range(query, min, nil) do
    from(p in query, where: p.price_cents >= ^min)
  end

  defp apply_price_range(query, nil, max) do
    from(p in query, where: p.price_cents <= ^max)
  end

  defp apply_price_range(query, min, max) do
    from(p in query, where: p.price_cents >= ^min and p.price_cents <= ^max)
  end

  @spec apply_stock_filter(Ecto.Query.t(), boolean() | nil) :: Ecto.Query.t()
  defp apply_stock_filter(query, nil), do: query
  defp apply_stock_filter(query, false), do: query

  defp apply_stock_filter(query, true) do
    from(p in query, where: p.stock_quantity > 0)
  end
end
```
