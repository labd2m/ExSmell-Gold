# Annotated Example — Speculative Assumptions

## Metadata

- **Smell name:** Speculative Assumptions
- **Expected smell location:** `Search.FacetExtractor.extract_price_range/1`, around the string-split range parsing
- **Affected function(s):** `extract_price_range/1`
- **Short explanation:** The function parses a price range filter string like `"100-500"` by splitting on `"-"` and using `Enum.at/2` to read the lower and upper bounds. If the price string uses a different separator (e.g., `":"` or `" to "`), or if a negative price appears (e.g., `"-50-200"` for a promotional adjustment), `Enum.at/2` returns the wrong fragment or `nil` silently. The search query is built with incorrect or `nil` price bounds, producing wrong search results without any error.

---

```elixir
defmodule Search.FacetExtractor do
  @moduledoc """
  Extracts and normalizes search filter facets from raw query parameters
  received from the product search API. Supports price ranges, category
  filters, brand filters, rating filters, and attribute filters.

  Price range format: "min-max" (e.g., "100-500", "0-9999")
  Rating filter format: "min_rating" (e.g., "4", "3.5")
  """

  require Logger

  @max_price        999_999
  @min_rating       1.0
  @max_rating       5.0
  @max_facet_values 50

  def extract(params) when is_map(params) do
    %{
      price_range:  extract_price_range(Map.get(params, "price_range")),
      categories:   extract_categories(Map.get(params, "categories")),
      brands:       extract_brands(Map.get(params, "brands")),
      rating:       extract_rating(Map.get(params, "min_rating")),
      attributes:   extract_attributes(Map.get(params, "attributes", %{})),
      in_stock_only: Map.get(params, "in_stock") == "true"
    }
  end

  # VALIDATION: SMELL START - Speculative Assumptions
  # VALIDATION: This is a smell because the function splits the price range string on
  # VALIDATION: "-" and uses Enum.at/2 with indices 0 and 1 to read the lower and
  # VALIDATION: upper bounds. This assumption breaks in at least two real cases:
  # VALIDATION: (1) If the price range uses a different separator such as ":" or " to ",
  # VALIDATION: the split produces a single-element list, Enum.at(parts, 1) returns nil,
  # VALIDATION: and parse_price/1 converts nil to nil — the upper bound silently disappears.
  # VALIDATION: (2) If a negative minimum price appears (e.g., "-50-500" for discounted
  # VALIDATION: items), splitting on "-" produces ["", "50", "500"], and Enum.at/2 reads
  # VALIDATION: "" as the lower and "50" as the upper — completely wrong. Neither case
  # VALIDATION: crashes; the function always returns a price_range map, so the search
  # VALIDATION: query silently uses wrong bounds and returns incorrect product results.
  def extract_price_range(nil), do: %{min: 0, max: @max_price}
  def extract_price_range(range_string) when is_binary(range_string) do
    parts = String.split(range_string, "-")

    min_price = parts |> Enum.at(0) |> parse_price() |> clamp_min()
    max_price = parts |> Enum.at(1) |> parse_price() |> clamp_max()

    %{min: min_price, max: max_price}
  end
  # VALIDATION: SMELL END

  def extract_price_range(_), do: %{min: 0, max: @max_price}

  defp extract_categories(nil), do: []
  defp extract_categories(str) when is_binary(str) do
    str
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.take(@max_facet_values)
  end

  defp extract_categories(list) when is_list(list), do: Enum.take(list, @max_facet_values)
  defp extract_categories(_), do: []

  defp extract_brands(nil), do: []
  defp extract_brands(str) when is_binary(str) do
    str
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.take(@max_facet_values)
  end

  defp extract_brands(list) when is_list(list), do: Enum.take(list, @max_facet_values)
  defp extract_brands(_), do: []

  defp extract_rating(nil), do: nil
  defp extract_rating(str) when is_binary(str) do
    case Float.parse(str) do
      {f, _} when f >= @min_rating and f <= @max_rating -> f
      _ -> nil
    end
  end

  defp extract_rating(_), do: nil

  defp extract_attributes(attrs) when is_map(attrs) do
    attrs
    |> Enum.map(fn {key, val} ->
      values = if is_binary(val), do: String.split(val, ","), else: List.wrap(val)
      {key, Enum.map(values, &String.trim/1)}
    end)
    |> Map.new()
  end

  defp extract_attributes(_), do: %{}

  defp parse_price(nil), do: nil
  defp parse_price(""), do: nil
  defp parse_price(str) do
    case Integer.parse(String.trim(str)) do
      {n, _} -> n
      :error -> nil
    end
  end

  defp clamp_min(nil), do: 0
  defp clamp_min(n) when n < 0, do: 0
  defp clamp_min(n), do: n

  defp clamp_max(nil), do: @max_price
  defp clamp_max(n) when n > @max_price, do: @max_price
  defp clamp_max(n), do: n

  def to_query_params(%{price_range: pr, categories: cats, brands: brands, rating: rating}) do
    base = %{"price_range" => "#{pr.min}-#{pr.max}"}

    base
    |> maybe_put("categories", Enum.join(cats, ","), cats != [])
    |> maybe_put("brands", Enum.join(brands, ","), brands != [])
    |> maybe_put("min_rating", to_string(rating), not is_nil(rating))
  end

  defp maybe_put(map, _key, _val, false), do: map
  defp maybe_put(map, key, val, true), do: Map.put(map, key, val)
end
```
