# Annotated Bad Example 34: Untested Polymorphic Behaviors

## Metadata

- **Smell name**: Untested Polymorphic Behaviors
- **Expected smell location**: `Search.QueryBuilder.merge_filters/2`
- **Affected function(s)**: `merge_filters/2`
- **Short explanation**: The function calls `Enum.reduce/3` on the `filters` parameter to merge filter maps, relying on the `Enumerable` protocol. There is no guard clause restricting the type of `filters`. Passing a plain `Map` instead of a list of maps (a natural mistake given that a single filter is also represented as a map) causes `Enum.reduce` to iterate over `{key, value}` tuples rather than filter maps, silently producing an incorrectly structured accumulator that corrupts the search query without raising any error. A single filter map would need to be wrapped in a list, and the lack of a guard makes this invisible at the call site.

## Code

```elixir
defmodule Search.QueryBuilder do
  @moduledoc """
  Builds structured search query maps for the full-text search service.
  Supports filter composition, sort specification, pagination, and
  field projection for the product catalog and document search APIs.
  """

  @default_page_size 20
  @max_page_size 200
  @default_sort_field "relevance"
  @default_sort_direction :desc

  @doc """
  Builds a complete search query map from its components.
  """
  def build_query(term, opts \\ []) when is_binary(term) do
    page = Keyword.get(opts, :page, 1)
    size = Keyword.get(opts, :size, @default_page_size)
    sort_field = Keyword.get(opts, :sort_field, @default_sort_field)
    sort_dir = Keyword.get(opts, :sort_direction, @default_sort_direction)
    filters = Keyword.get(opts, :filters, [])
    fields = Keyword.get(opts, :fields, :all)

    %{
      term: term,
      filters: merge_filters(filters, %{}),
      sort: %{field: sort_field, direction: sort_dir},
      pagination: build_pagination(page, size),
      fields: normalize_fields(fields)
    }
  end

  @doc """
  Merges a collection of filter maps into a single flat filter map.
  Later filters override earlier ones on key conflicts.

  ## Parameters
    - `filters`: A list of filter maps to merge.
    - `base`: The base filter map to merge into.
  """
  # VALIDATION: SMELL START - Untested Polymorphic Behaviors
  # VALIDATION: This is a smell because `Enum.reduce/3` depends on the `Enumerable`
  # protocol. There is no guard clause restricting `filters` to a list. Callers
  # that pass a single filter `Map` (e.g., `%{status: "active"}` instead of
  # `[%{status: "active"}]`) cause `Enum.reduce` to iterate over the map's
  # `{key, value}` tuples. The accumulate function `Map.merge(acc, filter)` then
  # tries to merge a `{:status, "active"}` tuple with a map, raising a
  # `BadMapError` rather than a `FunctionClauseError` at this function boundary —
  # making the root cause hard to identify. A guard `is_list(filters)` would catch
  # this immediately and clearly.
  def merge_filters(filters, base) when is_map(base) do
    Enum.reduce(filters, base, fn filter, acc ->
      Map.merge(acc, filter)
    end)
  end
  # VALIDATION: SMELL END

  @doc """
  Adds a single filter entry to an existing filter map.
  """
  def add_filter(filters, key, value)
      when is_map(filters) and is_atom(key) do
    Map.put(filters, key, value)
  end

  @doc """
  Removes a filter key from an existing filter map.
  """
  def remove_filter(filters, key)
      when is_map(filters) and is_atom(key) do
    Map.delete(filters, key)
  end

  @doc """
  Validates and clamps pagination parameters.
  Returns `{:ok, pagination_map}` or `{:error, reason}`.
  """
  def build_pagination(page, size)
      when is_integer(page) and is_integer(size) do
    cond do
      page < 1 -> {:error, :invalid_page}
      size < 1 -> {:error, :invalid_size}
      size > @max_page_size -> {:error, :size_exceeds_maximum}
      true -> {:ok, %{page: page, size: size, offset: (page - 1) * size}}
    end
  end

  @doc """
  Normalizes the field projection spec.
  `:all` returns `nil` (fetch all fields); a list of atoms returns a list of strings.
  """
  def normalize_fields(:all), do: nil

  def normalize_fields(fields) when is_list(fields) do
    Enum.map(fields, fn
      f when is_atom(f) -> Atom.to_string(f)
      f when is_binary(f) -> f
    end)
  end

  @doc """
  Returns a human-readable description of the query for logging.
  """
  def describe_query(%{term: term, filters: filters, pagination: pagination}) do
    filter_count = if is_map(filters), do: map_size(filters), else: 0

    page =
      case pagination do
        {:ok, %{page: p}} -> p
        %{page: p} -> p
        _ -> "?"
      end

    "Search: '#{term}' | filters=#{filter_count} | page=#{page}"
  end

  @doc """
  Returns whether a query has any active filters applied.
  """
  def has_filters?(%{filters: filters}) when is_map(filters), do: map_size(filters) > 0
  def has_filters?(_), do: false
end
```
