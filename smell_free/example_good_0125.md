```elixir
defmodule MyApp.Search.QueryBuilder do
  @moduledoc """
  Constructs `Elasticsearch` query DSL maps from a structured
  `SearchRequest` value. Each clause builder is a discrete private
  function so that individual filters can be added, changed, or
  removed independently without touching the others.

  The module is entirely stateless — no process, no configuration
  fetched from the Application environment.
  """

  alias MyApp.Search.SearchRequest

  @default_page_size 20
  @max_page_size 100

  @type es_query :: map()

  @doc """
  Builds a complete Elasticsearch query map from a `SearchRequest`.
  The result can be posted directly to the `_search` endpoint.
  """
  @spec build(SearchRequest.t()) :: es_query()
  def build(%SearchRequest{} = req) do
    %{
      "from" => offset(req),
      "size" => page_size(req),
      "query" => build_query(req),
      "sort" => build_sort(req),
      "_source" => build_source_filter(req)
    }
  end

  @spec build_query(SearchRequest.t()) :: map()
  defp build_query(req) do
    clauses =
      []
      |> maybe_add_fulltext(req)
      |> maybe_add_category_filter(req)
      |> maybe_add_price_range(req)
      |> maybe_add_availability_filter(req)

    case clauses do
      [] -> %{"match_all" => %{}}
      [single] -> single
      many -> %{"bool" => %{"must" => many}}
    end
  end

  @spec maybe_add_fulltext([map()], SearchRequest.t()) :: [map()]
  defp maybe_add_fulltext(clauses, %{query: q}) when is_binary(q) and byte_size(q) > 0 do
    clause = %{
      "multi_match" => %{
        "query" => q,
        "fields" => ["name^3", "description", "tags"],
        "type" => "best_fields",
        "fuzziness" => "AUTO"
      }
    }

    [clause | clauses]
  end

  defp maybe_add_fulltext(clauses, _), do: clauses

  @spec maybe_add_category_filter([map()], SearchRequest.t()) :: [map()]
  defp maybe_add_category_filter(clauses, %{category_slug: slug})
       when is_binary(slug) and byte_size(slug) > 0 do
    [%{"term" => %{"category_slug" => slug}} | clauses]
  end

  defp maybe_add_category_filter(clauses, _), do: clauses

  @spec maybe_add_price_range([map()], SearchRequest.t()) :: [map()]
  defp maybe_add_price_range(clauses, %{min_price_cents: min, max_price_cents: max})
       when is_integer(min) or is_integer(max) do
    range =
      %{}
      |> put_if_integer("gte", min)
      |> put_if_integer("lte", max)

    [%{"range" => %{"price_cents" => range}} | clauses]
  end

  defp maybe_add_price_range(clauses, _), do: clauses

  @spec maybe_add_availability_filter([map()], SearchRequest.t()) :: [map()]
  defp maybe_add_availability_filter(clauses, %{available_only: true}) do
    [%{"term" => %{"available" => true}} | clauses]
  end

  defp maybe_add_availability_filter(clauses, _), do: clauses

  @spec build_sort(SearchRequest.t()) :: [map()]
  defp build_sort(%{sort_by: :price_asc}),
    do: [%{"price_cents" => "asc"}]

  defp build_sort(%{sort_by: :price_desc}),
    do: [%{"price_cents" => "desc"}]

  defp build_sort(%{sort_by: :newest}),
    do: [%{"inserted_at" => "desc"}]

  defp build_sort(_),
    do: [%{"_score" => "desc"}]

  @spec build_source_filter(SearchRequest.t()) :: [String.t()]
  defp build_source_filter(%{fields: fields}) when is_list(fields) and length(fields) > 0,
    do: fields

  defp build_source_filter(_),
    do: ["id", "name", "price_cents", "available", "category_slug", "tags"]

  @spec offset(SearchRequest.t()) :: non_neg_integer()
  defp offset(%{page: page, page_size: size})
       when is_integer(page) and page > 0 and is_integer(size),
       do: (page - 1) * min(size, @max_page_size)

  defp offset(_), do: 0

  @spec page_size(SearchRequest.t()) :: pos_integer()
  defp page_size(%{page_size: size}) when is_integer(size) and size > 0,
    do: min(size, @max_page_size)

  defp page_size(_), do: @default_page_size

  @spec put_if_integer(map(), String.t(), integer() | nil) :: map()
  defp put_if_integer(m, _key, nil), do: m
  defp put_if_integer(m, key, val) when is_integer(val), do: Map.put(m, key, val)
end
```
