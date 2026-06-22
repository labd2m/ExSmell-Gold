```elixir
defmodule MyApp.Catalogue.SearchFacets do
  @moduledoc """
  Computes faceted counts for a product search result set. Each facet
  describes an attribute dimension (category, brand, price range, etc.)
  and the count of matching products within each bucket of that dimension.
  Counts are derived from a single aggregation query rather than N
  separate queries, keeping latency low even over large catalogues.
  """

  import Ecto.Query, warn: false

  alias MyApp.Repo
  alias MyApp.Catalogue.Product

  @price_buckets [
    {"under_25", 0, 2_499},
    {"25_to_50", 2_500, 4_999},
    {"50_to_100", 5_000, 9_999},
    {"over_100", 10_000, nil}
  ]

  @type bucket :: %{label: String.t(), count: non_neg_integer()}
  @type facet :: %{name: String.t(), buckets: [bucket()]}

  @doc """
  Computes search facets for the given base `query`. The query should
  represent the result set before pagination so that facet counts reflect
  the full matching set.
  """
  @spec compute(Ecto.Query.t()) :: [facet()]
  def compute(base_query) do
    [
      category_facet(base_query),
      brand_facet(base_query),
      availability_facet(base_query),
      price_facet(base_query)
    ]
  end

  @spec category_facet(Ecto.Query.t()) :: facet()
  defp category_facet(base_query) do
    buckets =
      base_query
      |> group_by([p], p.category_slug)
      |> select([p], {p.category_slug, count(p.id)})
      |> Repo.all()
      |> Enum.map(fn {slug, count} -> %{label: slug, count: count} end)
      |> Enum.sort_by(& &1.count, :desc)

    %{name: "category", buckets: buckets}
  end

  @spec brand_facet(Ecto.Query.t()) :: facet()
  defp brand_facet(base_query) do
    buckets =
      base_query
      |> where([p], not is_nil(p.brand))
      |> group_by([p], p.brand)
      |> select([p], {p.brand, count(p.id)})
      |> Repo.all()
      |> Enum.map(fn {brand, count} -> %{label: brand, count: count} end)
      |> Enum.sort_by(& &1.count, :desc)
      |> Enum.take(15)

    %{name: "brand", buckets: buckets}
  end

  @spec availability_facet(Ecto.Query.t()) :: facet()
  defp availability_facet(base_query) do
    counts =
      base_query
      |> group_by([p], p.available)
      |> select([p], {p.available, count(p.id)})
      |> Repo.all()
      |> Map.new()

    buckets = [
      %{label: "in_stock", count: Map.get(counts, true, 0)},
      %{label: "out_of_stock", count: Map.get(counts, false, 0)}
    ]

    %{name: "availability", buckets: buckets}
  end

  @spec price_facet(Ecto.Query.t()) :: facet()
  defp price_facet(base_query) do
    buckets =
      Enum.map(@price_buckets, fn {label, min_cents, max_cents} ->
        count =
          base_query
          |> apply_price_range(min_cents, max_cents)
          |> select([p], count(p.id))
          |> Repo.one()
          |> Kernel.||(0)

        %{label: label, count: count}
      end)

    %{name: "price", buckets: buckets}
  end

  @spec apply_price_range(Ecto.Query.t(), non_neg_integer(), pos_integer() | nil) :: Ecto.Query.t()
  defp apply_price_range(q, min, nil), do: where(q, [p], p.price_cents >= ^min)

  defp apply_price_range(q, min, max),
    do: where(q, [p], p.price_cents >= ^min and p.price_cents <= ^max)
end
```
