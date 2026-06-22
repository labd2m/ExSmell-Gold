```elixir
defmodule Catalog.SearchFacetBuilder do
  @moduledoc """
  Builds faceted search aggregations from a list of product records.
  Facets show available filter values and their counts so the search UI
  can display actionable refinement options. Each facet type has a
  dedicated builder. All computation is pure and operates on plain lists,
  making the module trivially testable and free of database dependency.
  """

  @type product :: %{
          category_slug: String.t(),
          brand: String.t() | nil,
          price_cents: non_neg_integer(),
          tags: [String.t()],
          condition: String.t(),
          in_stock: boolean()
        }

  @type facet_value :: %{value: term(), count: non_neg_integer()}
  @type price_range :: %{min: non_neg_integer(), max: non_neg_integer(), bucket_cents: pos_integer()}
  @type facets :: %{
          categories: [facet_value()],
          brands: [facet_value()],
          conditions: [facet_value()],
          tags: [facet_value()],
          price_ranges: [facet_value()],
          in_stock_count: non_neg_integer()
        }

  @price_buckets [
    {0, 2_499},
    {2_500, 4_999},
    {5_000, 9_999},
    {10_000, 24_999},
    {25_000, :infinity}
  ]

  @doc "Builds all facets from a list of product records."
  @spec build([product()]) :: facets()
  def build(products) when is_list(products) do
    %{
      categories: count_field(products, :category_slug),
      brands: count_field(products, :brand, &is_binary/1),
      conditions: count_field(products, :condition),
      tags: count_tags(products),
      price_ranges: count_price_ranges(products),
      in_stock_count: Enum.count(products, & &1.in_stock)
    }
  end

  @doc "Returns price range facets only, useful for range-slider UI components."
  @spec price_facets([product()]) :: [facet_value()]
  def price_facets(products) when is_list(products) do
    count_price_ranges(products)
  end

  @doc "Returns brand facets sorted by count descending, limited to `top_n`."
  @spec top_brands([product()], pos_integer()) :: [facet_value()]
  def top_brands(products, top_n \\ 10) when is_list(products) and is_integer(top_n) do
    products
    |> count_field(:brand, &is_binary/1)
    |> Enum.take(top_n)
  end

  defp count_field(products, field, filter_fn \\ fn _ -> true end) do
    products
    |> Enum.map(&Map.get(&1, field))
    |> Enum.filter(filter_fn)
    |> Enum.frequencies()
    |> Enum.map(fn {value, count} -> %{value: value, count: count} end)
    |> Enum.sort_by(& &1.count, :desc)
  end

  defp count_tags(products) do
    products
    |> Enum.flat_map(& &1.tags)
    |> Enum.frequencies()
    |> Enum.map(fn {tag, count} -> %{value: tag, count: count} end)
    |> Enum.sort_by(& &1.count, :desc)
  end

  defp count_price_ranges(products) do
    Enum.map(@price_buckets, fn {min, max} ->
      count =
        Enum.count(products, fn p ->
          p.price_cents >= min and (max == :infinity or p.price_cents <= max)
        end)

      label = if max == :infinity, do: "#{format_dollars(min)}+", else: "#{format_dollars(min)}–#{format_dollars(max)}"
      %{value: label, count: count}
    end)
  end

  defp format_dollars(cents) do
    "$#{div(cents, 100)}"
  end
end
```
