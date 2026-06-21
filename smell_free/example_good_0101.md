```elixir
defmodule Search.QueryBuilder do
  @moduledoc """
  Constructs Elasticsearch query DSL maps from typed search parameters.
  All transformation logic is pure and stateless; no process is involved.
  Each filter type is handled by a focused private builder so the top-level
  function remains a shallow composition of independent steps.
  """

  @type field :: String.t()
  @type sort_direction :: :asc | :desc
  @type date_range :: %{from: Date.t() | nil, to: Date.t() | nil}

  @type search_params :: %{
          optional(:term) => String.t(),
          optional(:fields) => [field()],
          optional(:filters) => %{optional(field()) => [term()]},
          optional(:date_range) => date_range(),
          optional(:sort_by) => field(),
          optional(:sort_dir) => sort_direction(),
          optional(:page) => pos_integer(),
          optional(:per_page) => pos_integer()
        }

  @default_per_page 20
  @default_fields ~w(title description tags)

  @doc """
  Builds an Elasticsearch query DSL map from `params`. Absent keys fall
  back to sensible defaults, so the caller is not required to provide
  all fields.
  """
  @spec build(search_params()) :: map()
  def build(params) when is_map(params) do
    %{
      query: build_query(params),
      sort: build_sort(params),
      from: page_offset(params),
      size: Map.get(params, :per_page, @default_per_page)
    }
  end

  defp build_query(%{term: term} = params) when is_binary(term) and byte_size(term) > 0 do
    fields = Map.get(params, :fields, @default_fields)

    must = [%{multi_match: %{query: term, fields: fields}}]
    filters = collect_filters(params)

    %{bool: %{must: must, filter: filters}}
  end

  defp build_query(params) do
    filters = collect_filters(params)
    %{bool: %{filter: filters}}
  end

  defp collect_filters(params) do
    []
    |> append_term_filters(Map.get(params, :filters, %{}))
    |> append_date_range(Map.get(params, :date_range))
  end

  defp append_term_filters(acc, filters) when map_size(filters) == 0, do: acc

  defp append_term_filters(acc, filters) do
    Enum.reduce(filters, acc, fn {field, values}, list ->
      [%{terms: %{field => values}} | list]
    end)
  end

  defp append_date_range(acc, nil), do: acc

  defp append_date_range(acc, %{from: nil, to: nil}), do: acc

  defp append_date_range(acc, range) do
    range_clause =
      %{}
      |> put_if_present(:gte, range[:from], &Date.to_iso8601/1)
      |> put_if_present(:lte, range[:to], &Date.to_iso8601/1)

    [%{range: %{"created_at" => range_clause}} | acc]
  end

  defp build_sort(%{sort_by: field, sort_dir: dir})
       when is_binary(field) and dir in [:asc, :desc] do
    [%{field => %{order: Atom.to_string(dir)}}]
  end

  defp build_sort(_params), do: [%{"_score" => %{order: "desc"}}]

  defp page_offset(%{page: page, per_page: per_page})
       when is_integer(page) and page > 0 and is_integer(per_page) do
    (page - 1) * per_page
  end

  defp page_offset(%{page: page}) when is_integer(page) and page > 0 do
    (page - 1) * @default_per_page
  end

  defp page_offset(_), do: 0

  defp put_if_present(map, _key, nil, _fun), do: map
  defp put_if_present(map, key, value, fun), do: Map.put(map, key, fun.(value))
end
```
