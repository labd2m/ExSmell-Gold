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
  def merge_filters(filters, base) when is_map(base) do
    Enum.reduce(filters, base, fn filter, acc ->
      Map.merge(acc, filter)
    end)
  end

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
