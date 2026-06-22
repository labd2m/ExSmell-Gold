```elixir
defmodule Platform.SearchFacets do
  @moduledoc """
  Computes faceted aggregations alongside search results for filter UIs.

  Facets describe the distribution of a result set across discrete field
  values (e.g., product category counts, price range buckets). Each facet
  is computed in a separate database query to keep individual queries simple.
  """

  import Ecto.Query, only: [from: 2]
  alias Platform.Repo

  @type facet_name :: atom()
  @type facet_value :: term()
  @type facet_count :: %{value: facet_value(), count: non_neg_integer()}
  @type price_bucket :: %{label: String.t(), min: integer(), max: integer() | nil, count: non_neg_integer()}
  @type facets :: %{optional(facet_name()) => [facet_count()] | [price_bucket()]}

  @price_buckets [
    %{label: "Under $25", min: 0, max: 2500},
    %{label: "$25 – $50", min: 2500, max: 5000},
    %{label: "$50 – $100", min: 5000, max: 10_000},
    %{label: "$100 – $250", min: 10_000, max: 25_000},
    %{label: "$250+", min: 25_000, max: nil}
  ]

  @doc """
  Computes all requested facets for the base `queryable`.

  `facet_fields` is a list of schema column atoms to facet on.
  Price faceting is automatically added when `:price_cents` is included.
  """
  @spec compute(Ecto.Queryable.t(), [facet_name()]) :: facets()
  def compute(queryable, facet_fields) when is_list(facet_fields) do
    facet_fields
    |> Enum.reduce(%{}, fn field, acc ->
      facet = compute_facet(queryable, field)
      Map.put(acc, field, facet)
    end)
  end

  @doc "Computes value distribution counts for a single enum-like field."
  @spec term_facet(Ecto.Queryable.t(), atom()) :: [facet_count()]
  def term_facet(queryable, field) when is_atom(field) do
    from(r in queryable,
      group_by: field(r, ^field),
      select: %{value: field(r, ^field), count: count(r.id)},
      order_by: [desc: count(r.id)]
    )
    |> Repo.all()
  end

  @doc "Computes price range bucket counts for a cents-valued field."
  @spec price_facet(Ecto.Queryable.t(), atom()) :: [price_bucket()]
  def price_facet(queryable, price_field \\ :price_cents) do
    Enum.map(@price_buckets, fn bucket ->
      count = count_in_range(queryable, price_field, bucket.min, bucket.max)
      Map.put(bucket, :count, count)
    end)
  end

  @doc "Computes a date histogram facet by month."
  @spec date_histogram(Ecto.Queryable.t(), atom()) :: [%{month: String.t(), count: non_neg_integer()}]
  def date_histogram(queryable, date_field) when is_atom(date_field) do
    from(r in queryable,
      group_by: fragment("date_trunc('month', ?)", field(r, ^date_field)),
      select: %{
        month: fragment("to_char(date_trunc('month', ?), 'YYYY-MM')", field(r, ^date_field)),
        count: count(r.id)
      },
      order_by: [asc: fragment("date_trunc('month', ?)", field(r, ^date_field))]
    )
    |> Repo.all()
  end

  defp compute_facet(queryable, :price_cents), do: price_facet(queryable, :price_cents)
  defp compute_facet(queryable, field), do: term_facet(queryable, field)

  defp count_in_range(queryable, field, min, nil) do
    from(r in queryable,
      where: field(r, ^field) >= ^min,
      select: count(r.id)
    )
    |> Repo.one()
  end

  defp count_in_range(queryable, field, min, max) do
    from(r in queryable,
      where: field(r, ^field) >= ^min and field(r, ^field) < ^max,
      select: count(r.id)
    )
    |> Repo.one()
  end
end
```
